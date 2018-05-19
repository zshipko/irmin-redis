open Lwt.Infix

open Hiredis

let to_string pp x = Fmt.strf "%a" pp x

module Key = struct
  let hostname =
    Irmin.Private.Conf.key
      ~doc:"Redis hostname"
      "hostname" Irmin.Private.Conf.string "127.0.0.1"

  let port =
    Irmin.Private.Conf.key
      ~doc:"port"
      "port" Irmin.Private.Conf.(some int) (Some 6379)

  let nclients =
    Irmin.Private.Conf.key
      ~doc:"nclients"
      "nclients" Irmin.Private.Conf.int 4
end

let config ?config:(config=Irmin.Private.Conf.empty) ?port ?nclients:(nclients=4) hostname =
  let module C = Irmin.Private.Conf in
  let config = C.add config Key.hostname hostname in
  let config = C.add config Key.port port in
  let config = C.add config Key.nclients nclients in
  config

let info ?author fmt =
  Fmt.kstrf (fun msg () ->
    let date = Int64.of_float (Unix.gettimeofday ()) in
    let author = match author with
      | Some a -> a
      | None   ->
        Printf.sprintf "%d@%s.[%d]" (Unix.getuid()) (Unix.gethostname()) (Unix.getpid())
    in
    Irmin.Info.v ~date ~author msg
  ) fmt

module RO (K: Irmin.Contents.Conv) (V: Irmin.Contents.Conv) = struct
  type key = K.t
  type value = V.t
  type t = Pool.t

  let v config =
    let module C = Irmin.Private.Conf in
    let hostname = C.get config Key.hostname in
    let port = C.get config Key.port in
    let nclients = C.get config Key.nclients in
    Lwt.return (Pool.create ?port hostname nclients)

  let find t key =
    Pool.use t (fun client ->
      let key = to_string K.pp key in
      match Client.run client [| "GET"; key |] with
      | String s ->
        begin
          match V.of_string s with
          | Ok s -> Lwt.return_some s
          | _ -> Lwt.return_none
        end
      | _ -> Lwt.return_none)

  let mem t key =
    Pool.use t (fun client ->
      let key = to_string K.pp key in
      match Client.run client [| "EXISTS"; key |] with
      | Integer 1L -> Lwt.return_true
      | _ -> Lwt.return_false)
end

module AO (K: Irmin.Hash.S) (V: Irmin.Contents.Conv) = struct
  include RO(K)(V)

  let add t value =
    Pool.use t (fun client ->
      let key = K.digest V.t value in
      let key' = to_string K.pp key in
      let value = to_string V.pp value in
      ignore (Client.run client [| "SET"; key'; value |]);
      Lwt.return key)
end

module Link (K: Irmin.Hash.S) = struct
  include RO(K)(K)

  let add t index key =
    Pool.use t (fun client ->
      let key = to_string K.pp key in
      let index = to_string K.pp index in
      ignore (Client.run client [| "SET"; index; key |]);
      Lwt.return_unit)
end

module RW (K: Irmin.Contents.Conv) (V: Irmin.Contents.Conv) = struct

  module RO = RO(K)(V)
  module W = Irmin.Private.Watch.Make(K)(V)

  type t = { t: RO.t; w: W.t }
  type key = RO.key
  type value = RO.value
  type watch = W.watch

  let watches = W.v ()

  let v config =
    RO.v config >>= fun t ->
    Lwt.return { t; w = watches }

  let find t = RO.find t.t
  let mem t = RO.mem t.t
  let watch_key t = W.watch_key t.w
  let watch t = W.watch t.w
  let unwatch t = W.unwatch t.w

  let list t =
    Pool.use t.t (fun client ->
      match Client.run client [| "KEYS"; "*" |] with
      | Array arr ->
          Array.map (fun k ->
            let k = Value.to_string k in
            K.of_string k
          ) arr
          |> Array.to_list
          |> Lwt_list.filter_map_s (function
            | Ok s -> Lwt.return_some s
            | _ -> Lwt.return_none)
      | _ -> Lwt.return []
    )

  let set t key value =
    Pool.use t.t (fun client ->
      let key' = to_string K.pp key in
      let value' = to_string V.pp value in
      match Client.run client [| "SET"; key'; value' |] with
      | Status "OK" -> W.notify t.w key (Some value)
      | _ -> Lwt.return_unit)

  let remove t key =
    Pool.use t.t (fun client ->
      let key' = to_string K.pp key in
      match Client.run client [| "DEL"; key' |] with
      | Status "OK" -> W.notify t.w key None
      | _ -> Lwt.return_unit)

  let set' = set
  let test_and_set t key ~test ~set =
    match set with
    | Some s ->
        set' t key s >>= fun () ->
        Lwt.return_true
    | None ->
        remove t key >>= fun () ->
        Lwt.return_true

end

module Make = Irmin.Make(AO)(RW)

module KV (C: Irmin.Contents.S) =
  Make
    (Irmin.Metadata.None)
    (C)
    (Irmin.Path.String_list)
    (Irmin.Branch.String)
    (Irmin.Hash.SHA1)
