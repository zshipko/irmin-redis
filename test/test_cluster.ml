open Lwt.Infix
open Irmin_test

let create_cluster start_port n =
  let config = [
    "cluster-enabled", ["yes"];
    "cluster-config-file", ["nodes.conf"];
    "cluster-node-timeout", ["5000"];
    "appendonly", ["yes"];
    "pidfile", ["redis.pid"];
  ] in
  let l = ref [] in
  let s = ref "" in
  let () = try Unix.mkdir "cluster" 0o766 with _ -> () in
  for i = 0 to n - 1 do
    let port = start_port + i in
    let port_path = "cluster/" ^ string_of_int port in
    let _ = try Unix.mkdir port_path 0o766 with _ -> () in
    Unix.chdir port_path;
    let _client = Hiredis.Shell.Server.start ~config:(("port", [port_path])::config) port in
    l := _client :: !l;
    s := !s ^ " 127.0.0.1:" ^ string_of_int port;
    Unix.chdir "../.."
  done;
  Unix.system ("./redis-trib.rb create" ^ !s) |> ignore;
  !l

let start () =
  create_cluster 7000 6

let stop servers =
  List.iter (fun server ->
    Hiredis.Shell.Server.stop server) servers

let servers = start ()

let store = store (module Irmin_redis.Make) (module Irmin.Metadata.None)

module Link = struct
  include Irmin_redis.Link(Irmin.Hash.SHA1)
  let v () = v (Irmin_redis.config ~port:7001 "127.0.0.1")
end

let link = (module Link: Test_link.S)
let config = Irmin_redis.config ~port:7000 "127.0.0.1"

let clean () =
  let (module S: Test_S) = store in
  S.Repo.v config >>= fun repo ->
  S.Repo.branches repo >>= Lwt_list.iter_p (S.Branch.remove repo)

let init () = Lwt.return_unit
let stats = None
let suite = { name = "REDIS-CLUSTER"; init; clean; config; store; stats }
