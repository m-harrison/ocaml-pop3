(** State machine representing POP3 server. *)

open Store
open Unix

(** The inner state of the POP3 'Authorization' state.

    The [string option] value is the mailbox identifier if USER+PASS
    authorization is being used and the previously issued command was a
    successful USER command. *)
type authorization_state =
  | Banner of tm
  (** Initial state and that returned to on unsuccessful authorization attempts.

      The [tm] value is the 'banner time' of the connection which can be used
      for APOP authorization. *)
  | Mailbox of tm * string
  (** Intermediate state after successful USER command.

      The [tm] value is the 'banner time' of the connection which can be used
      for APOP authorization should the subsequent PASS command fail and the
      initial state is returned to. *)
  | Quit
  (** Abort state when QUIT command is issued. *)

(** The inner state of the POP3 'Transaction' state.

    The [string] value is the mailbox identifier that has been authorized
    previously in the session. *)
type transaction_state = string

(** The inner state of the POP3 'Update' state.

    The [string] value is the mailbox identifier that has been authorized
    previously in the session. *)
type update_state = string

(** Result of handling a command. This records state, reply to send to client
    and whether to move into next session state. *)
type 'a command_result = {
  state : 'a;
  reply : Reply.t;
  next : bool;
}

(** Module type for generating 'banner time' when connections are created. *)
module type Banner = sig
  val get_time : unit -> tm
end

(** Implementation of [Banner] module type for [gmtime]. *)
module GmTimeBanner : Banner

(** State functor encapsulates server POP3 server state. Its parameters handle
    the greeting banner for new connections and the underlying store for secrets
    and mail drops. *)
module State (B : Banner) (S : Store) : sig
  (** POP3 session states as defined in RFC 1939. *)
  type t =
    | Disconnected
    (** [Disconnected] represents the termination of the POP3 session. *)
    | Authorization of authorization_state
    (** [Authorization] represents the initial state of the POP3 session. *)
    | Transaction of transaction_state
    (** [Authorization] represents the intermediate state of the POP3
        session. *)
    | Update of update_state
    (** [Update] represents the final state of the POP3 session. *)

  (** Start a new POP3 session with 'banner time' from [B] whenever [start] is
      evaluated.

    @return a new state machine [t] in the initial [Authorization] state with a
            current 'banner time'. *)
  val start : unit -> t

  (** Function to drive state machine from the client command passed as an
    argument.

    @return tuple of next state and reply to send to client in a lightweight
            thread. *)
  val f : t -> Command.t -> (t * Reply.t) Lwt.t
end
