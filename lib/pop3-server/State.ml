open Lwt.Infix
open Store

module type Banner = sig
  val time : unit -> Unix.tm
end

module GmTimeBanner : Banner = struct
  let time () =
    Unix.time () |> Unix.gmtime
end

module type State = sig
  type t

  val start : string -> string -> t Lwt.t

  val banner_time : t -> Unix.tm

  val terminated : t -> bool

  val f : t -> Pop3.Command.t -> (t * Pop3.Reply.t) Lwt.t
end

module BackingStoreState (B : Banner) (S : Store) : State = struct
  open Pop3.Command

  type pop3_session_state =
    | Disconnected
    | Authorization of string option
    | Transaction   of string
    | Update        of string

  (* Abstracted state type is (hostname, session_state, banner_time, store). *)
  type t = string * pop3_session_state * Unix.tm * S.t

  let start h p =
    S.init p
    >|= fun store -> (h, Authorization None, B.time (), store)

  let banner_time (_,_,t,_) = t

  let terminated (_,s,_,_) = (s = Disconnected)

  let auth_fail hostname store banner_time =
    ((hostname, Authorization None, banner_time, store),
      Pop3.Reply.err (Some "permission denied"))

  let auth_invalid_cmd hostname store banner_time =
    ((hostname, Authorization None, banner_time, store),
      Pop3.Reply.err (Some "command invalid before authorized"))

  let auth_quit hostname store banner_time =
    ((hostname, Disconnected, banner_time, store),
      Pop3.Reply.ok (Some (Printf.sprintf "%s POP3 server signing off" hostname)) [])

  let auth_result hostname store banner_time mailbox success =
    if success then
      (* Authorization was successful so move into Transaction state. *)
      ((hostname, Transaction mailbox, banner_time, store),
        Pop3.Reply.ok (Some "maildrop locked and ready") [])
    else
      (* Authorization was unsuccessful so fail and reset memoized mailbox. *)
      auth_fail hostname store banner_time

  let auth_apop hostname store banner_time mailbox digest =
    S.apop_of_mailbox store banner_time hostname mailbox
    >|= fun digest_option ->
      match digest_option with
      | None ->
        (* Mailbox does not exist so fail. *)
        auth_fail hostname store banner_time
      | Some digest' ->
        (* Compare actual computed digest against provided digest for mailbox. *)
        auth_result hostname store banner_time mailbox (digest = digest')

  let auth_pass hostname store banner_time mailbox_opt secret =
    match mailbox_opt with
    | None ->
      (* No mailbox memoized so nothing to authorize against. *)
      Lwt.return (auth_fail hostname store banner_time)
    | Some mailbox ->
      (* Verify provided secret against secret for memoized mailbox. *)
      S.secret_of_mailbox store mailbox
      >|= fun secret_option ->
        match secret_option with
        | None ->
          (* Memoized mailbox does not exist so fail. *)
          auth_fail hostname store banner_time
        | Some secret' ->
          (* Compare actual secret against provided secret for memoized mailbox. *)
          auth_result hostname store banner_time mailbox (secret = secret')

  let auth_user hostname store banner_time mailbox =
    Lwt.return
      ((hostname, Authorization (Some mailbox), banner_time, store),
        Pop3.Reply.ok (Some mailbox) [])

  let f_auth hostname store banner_time mailbox cmd =
    match cmd with
    | Apop (mailbox', digest) ->
      (* Attempt to verify digest, if this fails reset memoized mailbox. *)
      auth_apop hostname store banner_time mailbox' digest
    | Pass secret ->
      (* Attempt to verify secret for memoized mailbox. *)
      auth_pass hostname store banner_time mailbox secret
    | Quit ->
      (* Terminate the session. *)
      Lwt.return (auth_quit hostname store banner_time)
    | User mailbox' ->
      (* Reset memoized mailbox and return +OK ready for PASS command. *)
      auth_user hostname store banner_time mailbox'
    | _ ->
      (* Other commands are invalid in Authorization state. *)
      Lwt.return (auth_invalid_cmd hostname store banner_time)

  let trans_fail hostname store banner_time mailbox =
    ((hostname, Transaction mailbox, banner_time, store), Pop3.Reply.err None)

  let trans_not_implemented hostname store banner_time mailbox =
    Lwt.return
      ((hostname, Transaction mailbox, banner_time, store),
        Pop3.Reply.err (Some "not implemented"))

  let trans_drop_listing store mailbox =
    S.message_list_of_mailbox store mailbox
    >>= Lwt_list.map_s
      (fun msg ->
        S.lines_of_message store mailbox msg
        >|= fun ls_opt ->
          (match ls_opt with
          | None -> (msg, None)
          | Some ls ->
            (msg,
              Some ((String.concat "\r\n" ls
              |> Bytes.of_string
              |> Bytes.length) + 2))))
    >|= List.fold_left
      (fun (ms, n, s) -> fun (msg, os_opt) ->
        match os_opt with
        | None    -> (ms, n, s)
        | Some os ->
          (((Printf.sprintf "%d %d" msg os)::ms), (n+1), (os+s)))
      ([], 0, 0)
    >|= (fun (ls, num, size) -> ((List.rev ls), num, size))

  let trans_list_none hostname store banner_time mailbox =
    trans_drop_listing store mailbox
    >|= (fun (ls, num, size) ->
      ((hostname, Transaction mailbox, banner_time, store),
        Pop3.Reply.ok (Some (Printf.sprintf "%d messages (%d octets)" num size)) ls))

  let trans_list_some hostname store banner_time mailbox msg =
    S.lines_of_message store mailbox msg
    >|= fun ls_opt ->
      match ls_opt with
      | None    -> trans_fail hostname store banner_time mailbox
      | Some ls ->
        let octets =
          (ls |> String.concat "\r\n" |> Bytes.of_string |> Bytes.length) + 2 in
        ((hostname, Transaction mailbox, banner_time, store),
          Pop3.Reply.ok (Some (Printf.sprintf "%d %d" msg octets)) [])

  let trans_noop hostname store banner_time mailbox =
    Lwt.return
      ((hostname, Transaction mailbox, banner_time, store),
        Pop3.Reply.ok None [])

  let trans_quit hostname store banner_time mailbox =
    ((hostname, Update mailbox, banner_time, store), Pop3.Reply.ok None [])

  let trans_retr hostname store banner_time mailbox msg =
    S.lines_of_message store mailbox msg
    >|= fun ls_option ->
      match ls_option with
      | None -> trans_fail hostname store banner_time mailbox
      | Some ls ->
        let octets =
          (ls |> String.concat "\r\n" |> Bytes.of_string |> Bytes.length) + 2 in
        ((hostname, Transaction mailbox, banner_time, store),
          Pop3.Reply.ok (Some (Printf.sprintf "%d octets" octets)) ls)

  let trans_stat hostname store banner_time mailbox =
    trans_drop_listing store mailbox
    >|= (fun (_, num, size) ->
      ((hostname, Transaction mailbox, banner_time, store),
        Pop3.Reply.ok (Some (Printf.sprintf "%d %d" num size)) []))

  let trans_top hostname store banner_time mailbox msg n =
    let rec top ls m =
      if m = 0 then [] else
      match ls with
      | []     -> []
      | l::ls' -> l::(top ls' (m-1))
    in

    S.lines_of_message store mailbox msg
    >|= fun ls_option ->
      match ls_option with
      | None -> trans_fail hostname store banner_time mailbox
      | Some ls ->
        ((hostname, Transaction mailbox, banner_time, store),
          Pop3.Reply.ok None (top ls n))

  let trans_uidl_none hostname store banner_time mailbox =
    S.message_list_of_mailbox store mailbox
    >>= Lwt_list.map_s
      (fun msg ->
        S.uid_of_message store mailbox msg
        >|= fun uid_opt -> (msg, uid_opt))
    >|= List.map
      (fun (msg, uid_opt) ->
        match uid_opt with
        | Some uid -> Printf.sprintf "%d %s" msg uid
        | None     -> "")
    >|= List.filter (fun line -> line <> "")
    >|= fun ls ->
      ((hostname, Transaction mailbox, banner_time, store),
        Pop3.Reply.ok None ls)

  let trans_uidl_some hostname store banner_time mailbox msg =
    S.uid_of_message store mailbox msg
    >|= fun uid_option ->
      match uid_option with
      | None -> trans_fail hostname store banner_time mailbox
      | Some uid ->
        ((hostname, Transaction mailbox, banner_time, store),
          Pop3.Reply.ok (Some (Printf.sprintf "%d %s" msg uid)) [])

  let trans_invalid_command hostname store banner_time mailbox =
    ((hostname, Update mailbox, banner_time, store),
      Pop3.Reply.err (Some "command invalid while issuing transactions"))

  let f_trans hostname store banner_time mailbox cmd =
    match cmd with
    | Dele _msg ->
      (* Mark message with 'message number' [msg] for deletion. *)
      trans_not_implemented hostname store banner_time mailbox
    | List None ->
      (* Scan list entire mailbox. *)
      trans_list_none hostname store banner_time mailbox
    | List (Some msg) ->
      (* Scan list message with 'message number' [msg]. *)
      trans_list_some hostname store banner_time mailbox msg
    | Noop ->
      (* Ping back '+OK' but take no other action. *)
      trans_noop hostname store banner_time mailbox
    | Quit ->
      (* Stop accepting transactions and move to the Update state. *)
      Lwt.return (trans_quit hostname store banner_time mailbox)
    | Retr msg ->
      (* Read message with 'message number' [msg]. *)
      trans_retr hostname store banner_time mailbox msg
    | Rset ->
      (* Resets messages that are marked for deletion. *)
      trans_not_implemented hostname store banner_time mailbox
    | Stat ->
      (* Drop list entire mailbox. *)
      trans_stat hostname store banner_time mailbox
    | Top (msg, n) ->
      (* Reads top [n] lines from message with 'message number' [msg]. *)
      trans_top hostname store banner_time mailbox msg n
    | Uidl None ->
      (* Provides unique identifiers for all messages in mailbox. *)
      trans_uidl_none hostname store banner_time mailbox
    | Uidl (Some msg) ->
      (* Provides unique identifier for message with 'message number' [msg]. *)
      trans_uidl_some hostname store banner_time mailbox msg
    | _ ->
      (* Other commands are invalid in Transaction state. *)
      Lwt.return (trans_invalid_command hostname store banner_time mailbox)

  let update_quit hostname store banner_time _mailbox =
    Lwt.return ((hostname, Disconnected, banner_time, store),
      Pop3.Reply.ok (Some (Printf.sprintf "%s POP3 server signing off" hostname)) [])

  let update_invalid_cmd hostname store banner_time mailbox =
    ((hostname, Update mailbox, banner_time, store),
      Pop3.Reply.err (Some "command invalid after quiting transactions"))

  let f_update hostname store banner_time mailbox cmd =
    match cmd with
    | Quit ->
      (* Terminate the session. *)
      update_quit hostname store banner_time mailbox
    | _    ->
      (* Other commands are invalid in Update state. *)
      Lwt.return (update_invalid_cmd hostname store banner_time mailbox)

  let f (hostname, state, banner_time, store) cmd =
    match state with
    | Authorization mailbox_opt ->
      (* Drop into the handler for commands when in the Authorization state. *)
      f_auth hostname store banner_time mailbox_opt cmd
    | Disconnected ->
      (* The 'Disconnected' state cannot accept commands. *)
      Lwt.return ((hostname, Disconnected, banner_time, store), Pop3.Reply.Common.internal_error)
    | Transaction mailbox ->
      (* Drop into the handler for commands when in the Transaction state. *)
      f_trans hostname store banner_time mailbox cmd
    | Update mailbox ->
      (* Drop into the handler for commands when in the Update state. *)
      f_update hostname store banner_time mailbox cmd
end
