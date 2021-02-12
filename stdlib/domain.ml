module Raw = struct
  (* Low-level primitives provided by the runtime *)
  type t = private int
  external critical_adjust : int -> unit
    = "caml_ml_domain_critical_section"
  external interrupt : t -> unit
    = "caml_ml_domain_interrupt"
  external wait : unit -> unit
    = "caml_ml_domain_yield"
  type timeout_or_notified = Timeout | Notified
  external wait_until : int64 -> timeout_or_notified
    = "caml_ml_domain_yield_until"
  external spawn : (unit -> unit) -> t
    = "caml_domain_spawn"
  external self : unit -> t
    = "caml_ml_domain_id"
  external cpu_relax : unit -> unit
    = "caml_ml_domain_cpu_relax"
end

type nanoseconds = int64
external timer_ticks : unit -> (int64 [@unboxed]) =
  "caml_ml_domain_ticks" "caml_ml_domain_ticks_unboxed" [@@noalloc]

module Sync = struct
  exception Retry
  let rec critical_section f =
    failwith "critical_section not implemented"
    (*Raw.critical_adjust (+1);
    match f () with
    | x -> Raw.critical_adjust (-1); x
    | exception Retry -> Raw.critical_adjust (-1); Raw.cpu_relax (); critical_section f
    | exception ex -> Raw.critical_adjust (-1); raise ex *)

  let notify d = 
      failwith "notify not implemented"
(*       Raw.interrupt d *)

  let wait () =  
      failwith "wait not implemented"
(*       Raw.wait () *)

  type timeout_or_notified =
    Raw.timeout_or_notified =
      Timeout | Notified

  let wait_until t = 
      failwith "wait_until not implemented"
(*       Raw.wait_until t *)

  let wait_for dt = 
      failwith "wait_for not implemented"
(*       Raw.wait_until (Int64.add (timer_ticks ()) dt) *)

  let cpu_relax () = Raw.cpu_relax ()
  external poll : unit -> unit = "%poll"
end

module Mutex = struct
  type t
  external create : unit -> t = "caml_mutex_new"
  external lock : t -> unit = "caml_mutex_lock"
  external unlock : t -> unit = "caml_mutex_unlock" [@@noalloc]
  external try_lock : t -> bool = "caml_mutex_try_lock" [@@noalloc]
end

module Condition = struct
  type t
  external create : Mutex.t -> t = "caml_condition_new"
  external wait : t -> unit = "caml_condition_wait"
  external broadcast : t -> unit = "caml_condition_broadcast" [@@noalloc]
  external signal : t -> unit = "caml_condition_signal" [@@noalloc]
end

type id = Raw.t

type 'a state =
| Running
| Joining of ('a, exn) result option ref * Mutex.t * Condition.t
| Finished of ('a, exn) result
| Joined

type 'a t =
    { domain : Raw.t; state : 'a state Atomic.t; mutex : Mutex.t; cond : Condition.t }

exception Retry
let rec spin f =
  try f () with Retry ->
(*      Raw.cpu_relax (); *)
     spin f

let cas r vold vnew =
  if not (Atomic.compare_and_set r vold vnew) then raise Retry

let spawn f =
  let state = Atomic.make Running in
  let body () =
    let result = match f () with
      | x -> Ok x
      | exception ex -> Error ex in
    (* Begin a critical section that is ended by domain
       termination *)
(*     Raw.critical_adjust (+1); *)
    spin (fun () ->
      match Atomic.get state with
      | Running ->
         cas state Running (Finished result)
      | Joining (r, mutex, cond) as old ->
         cas state old Joined;
         Mutex.lock mutex;
         r := Some result;
         Condition.signal cond;
         Mutex.unlock mutex
(*          Raw.interrupt d *)
      | Joined | Finished _ ->
         failwith "internal error: I'm already finished?") in
  let mutex = Mutex.create () in
  { domain = Raw.spawn body; state; mutex; cond = Condition.create mutex }

let join { domain ; state; mutex; cond } =
  let res = spin (fun () ->
    match Atomic.get state with
    | Running ->
       let res = ref None in
       cas state Running (Joining (res, mutex, cond));
       Mutex.lock mutex;
       let rec check_res () = match !res with
           | None -> Condition.wait cond; check_res ()
           | Some r -> r
       in
       let r = check_res () in
       Mutex.unlock mutex;
       r
    | Finished res as old ->
       cas state old Joined;
       res
    | Joining _ | Joined ->
       raise (Invalid_argument "This domain has already been joined")) in
  (* Wait until the domain has terminated.
     The domain is in a critical section which will be
     ended by the runtime when it terminates *)
(*   Sync.notify domain; *)
  match res with
  | Ok x -> x
  | Error ex -> raise ex


let get_id { domain; _ } = domain

let self () = Raw.self ()

module DLS = struct

  type 'a key = int ref

  type entry = {key: int ref; slot: Obj.t ref}

  external get_dls_list : unit -> entry list
    = "caml_domain_dls_get" [@@noalloc]

  external set_dls_list : entry list  -> unit
    = "caml_domain_dls_set" [@@noalloc]

  let new_key () = ref 0

  let set k x =
    let cs = Obj.repr x in
    let old = get_dls_list () in
    let rec add_or_update_entry k v l =
      match l with
      | [] -> Some {key = k; slot = ref v}
      | hd::tl -> if (hd.key == k) then begin
        hd.slot := v;
        None
      end else add_or_update_entry k v tl
    in
    match add_or_update_entry k cs old with
    | None -> ()
    | Some e -> set_dls_list (e::old)

  let get k =
    let vals = get_dls_list () in
    let rec search k l =
      match l with
      | [] -> None
      | hd::tl -> if hd.key == k then Some !(hd.slot) else search k tl
    in
    Obj.magic @@ search k vals

end
