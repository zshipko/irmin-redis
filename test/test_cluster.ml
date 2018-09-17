open Lwt.Infix
open Irmin_test

let start () =
  let start_port = 7000 in
  let n = 3 in
  let config =
    [ ("cluster-enabled", ["yes"])
    ; ("cluster-config-file", ["nodes.conf"])
    ; ("cluster-node-timeout", ["5000"])
    ; ("appendonly", ["yes"])
    ; ("pidfile", ["redis.pid"]) ]
  in
  let l = ref [] in
  let s = ref "" in
  let () = try Unix.mkdir "cluster" 0o766 with _ -> () in
  for i = 0 to n - 1 do
    let port = start_port + i in
    let port_path = "cluster/" ^ string_of_int port in
    let _ = try Unix.mkdir port_path 0o766 with _ -> () in
    Unix.chdir port_path;
    let _client =
      Hiredis.Shell.Server.start ~config:(("port", [port_path]) :: config) port
    in
    l := _client :: !l;
    s := !s ^ " 127.0.0.1:" ^ string_of_int port;
    Unix.chdir "../.."
  done;
  Unix.sleep 5;
  for i = 0 to n - 1 do
    let port = start_port + i in
    let client = Hiredis.Client.connect ~port "127.0.0.1" in
    for j = 0 to n - 1 do
      if i <> j then
        Hiredis.Client.run client
          [|"CLUSTER"; "MEET"; "127.0.0.1"; string_of_int (start_port + j)|]
        |> Hiredis_value.to_string
        |> print_endline
    done
  done;
  let a = Hiredis.Client.connect ~port:7000 "127.0.0.1" in
  let b = Hiredis.Client.connect ~port:7001 "127.0.0.1" in
  let c = Hiredis.Client.connect ~port:7002 "127.0.0.1" in
  for slot = 0 to 5461 do
    Hiredis.Client.run a [|"CLUSTER"; "ADDSLOTS"; string_of_int slot|]
    |> ignore
  done;
  for slot = 5462 to 10923 do
    Hiredis.Client.run b [|"CLUSTER"; "ADDSLOTS"; string_of_int slot|]
    |> ignore
  done;
  for slot = 10924 to 16383 do
    Hiredis.Client.run c [|"CLUSTER"; "ADDSLOTS"; string_of_int slot|]
    |> ignore
  done;
  Unix.sleep 5;
  !l


let stop servers =
  List.iter (fun server -> Hiredis.Shell.Server.stop server) servers


let servers = start ()

let store = store (module Irmin_redis.Make) (module Irmin.Metadata.None)

module Link = struct
  include Irmin_redis.Link (Irmin.Hash.SHA1)

  let v () = v (Irmin_redis.config ~port:7001 "127.0.0.1")
end

let link = (module Link : Irmin_test.Link.S)

let config = Irmin_redis.config ~port:7000 "127.0.0.1"

let clean () =
  let (module S : Irmin_test.S) = store in
  S.Repo.v config
  >>= fun repo ->
  S.Repo.branches repo >>= Lwt_list.iter_p (S.Branch.remove repo)


let init () = Lwt.return_unit

let stats = None

let suite = {name = "REDIS-CLUSTER"; init; clean; config; store; stats}
