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

let config ?config:(config=Irmin.Private.Conf.empty) ?root:(root="irmin") ?port ?nclients:(nclients=4) hostname =
  let module C = Irmin.Private.Conf in
  let config = C.add config Irmin.Private.Conf.root (Some root) in
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

type client = {
  mutable handle: Hiredis.Client.t;
}

let rec run client args = match Client.run client.handle args with
  | Error s when (try String.sub s 0 3 = "ASK" with _ -> false) ->
    let addr = String.split_on_char ' ' s |> List.rev |> List.hd in
    (match String.split_on_char ':' addr with
    | host::port::_ ->
      let client' = Hiredis.Client.connect ~port:(int_of_string port) host in
      run {handle = client'} args
    | _ -> Value.nil)
  | Error s when (try String.sub s 0 5 = "MOVED" with _ -> false) ->
    let addr = String.split_on_char ' ' s |> List.rev |> List.hd in
    (match String.split_on_char ':' addr with
    | host::port::_ ->
      client.handle <- Hiredis.Client.connect ~port:(int_of_string port) host;
      run client args
    | _ -> Value.nil)
  | x -> x

module RO (K: Irmin.Contents.Conv) (V: Irmin.Contents.Conv) = struct
  type key = K.t
  type value = V.t
  type t = string * Pool.t

  let v prefix config =
    let module C = Irmin.Private.Conf in
    let root = match C.get config Irmin.Private.Conf.root with
      | Some root -> root ^ ":" ^ prefix ^ ":"
      | None -> prefix ^ ":"
    in
    let hostname = C.get config Key.hostname in
    let port = C.get config Key.port in
    let nclients = C.get config Key.nclients in
    Lwt.return (root, Pool.create ?port hostname nclients)

  let find (root, t) key =
    Pool.use t (fun client ->
      let key = to_string K.pp key in
      match run {handle = client} [| "GET"; root ^  key |] with
      | String s ->
        begin
          match V.of_string s with
          | Ok s -> Lwt.return_some s
          | _ -> Lwt.return_none
        end
      | _ -> Lwt.return_none)

  let mem (root, t) key =
    Pool.use t (fun client ->
      let key = to_string K.pp key in
      match run {handle = client} [| "EXISTS"; root ^ key |] with
      | Integer 1L -> Lwt.return_true
      | _ -> Lwt.return_false)
end

module AO (K: Irmin.Hash.S) (V: Irmin.Contents.Conv) = struct
  include RO(K)(V)

  let v = v "obj"

  let add (root, t) value =
    Pool.use t (fun client ->
      let key = K.digest V.t value in
      let key' = to_string K.pp key in
      let value = to_string V.pp value in
      ignore (run {handle = client} [| "SET"; root ^ key'; value |]);
      Lwt.return key)
end

module Link (K: Irmin.Hash.S) = struct
  include RO(K)(K)

  let v = v "link"

  let add (root, t) index key =
    Pool.use t (fun client ->
      let key = to_string K.pp key in
      let index = to_string K.pp index in
      ignore (run {handle = client} [| "SET"; root ^ index; key |]);
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
    RO.v "data" config >>= fun t ->
    Lwt.return { t; w = watches }

  let find t = RO.find t.t
  let mem t  = RO.mem t.t
  let watch_key t key = Fmt.pr "%a\n%!" K.pp key; W.watch_key t.w key
  let watch t = W.watch t.w
  let unwatch t = W.unwatch t.w

  let list {t = (root, t); _} =
    let aux client =
      match run client [| "KEYS"; root ^ "*" |] with
      | Array arr ->
          Array.map (fun k ->
            let k = Value.to_string k in
            let offs = String.length root in
            let k = String.sub k offs (String.length k - offs) in
            K.of_string k
          ) arr
          |> Array.to_list
          |> Lwt_list.filter_map_s (function
            | Ok s -> Lwt.return_some s
            | _ -> Lwt.return_none)
      | _ -> Lwt.return []
    in
    Pool.use t (fun client ->
      match run {handle = client} [| "CLUSTER"; "slots" |] with
      | Error _ -> aux {handle = client}
      | Array nodes ->
          Array.fold_right (fun node acc ->
            let node = Value.to_array node in
            let info = Value.to_array node.(2) in
            let host = Value.to_string info.(0) in
            let port = Value.to_int info.(1) in
            let c = Client.connect ~port host in
            acc >>= fun acc ->
            aux {handle = c} >|= fun l -> acc @ l) nodes (Lwt.return [])
      | _ -> Lwt.return [])

  let set {t = (root, t); w} key value =
    Pool.use t (fun client ->
      let key' = to_string K.pp key in
      let value' = to_string V.pp value in
      match run {handle = client} [| "SET"; root ^ key'; value' |] with
      | Status "OK" -> W.notify w key (Some value)
      | _ -> Lwt.return_unit)

  let remove {t = (root, t); w} key =
    Pool.use t (fun client ->
      let key' = to_string K.pp key in
      ignore (run {handle = client} [| "DEL"; root ^ key' |]);
      W.notify w key None)

  let txn client args =
    ignore @@ run client [| "MULTI" |];
    ignore @@ run client args;
    run client [| "EXEC" |] <> Nil

  let test_and_set t key ~test ~set:s =
    let root, db = t.t in
    let key' = to_string K.pp key in
    Pool.use db (fun client ->
      let client = {handle = client} in
      ignore @@ run client [| "WATCH"; root ^ key' |];
      find t key >>= fun v ->
      if Irmin.Type.(equal (option V.t)) test v then (
      (match s with
        | None ->
            if txn client [| "DEL"; root ^ key' |] then
              W.notify t.w key None >>= fun () ->
              Lwt.return_true
            else
              Lwt.return_false
        | Some v ->
            let v' = to_string V.pp v in
            if txn client [| "SET"; root ^ key'; v' |] then
              W.notify t.w key (Some v) >>= fun () ->
              Lwt.return_true
            else
              Lwt.return_false
      ) >>= fun ok ->
        Lwt.return ok
      ) else (
        ignore @@ run client [| "UNWATCH"; root ^ key' |];
        Lwt.return_false
      )
    )
end

module Make = Irmin.Make(AO)(RW)

module KV (C: Irmin.Contents.S) =
  Make
    (Irmin.Metadata.None)
    (C)
    (Irmin.Path.String_list)
    (Irmin.Branch.String)
    (Irmin.Hash.SHA1)

