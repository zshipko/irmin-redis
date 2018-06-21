(*
 * Copyright (c) 2013-2017 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Irmin_test

let port = 9999
let server = Hiredis.Shell.Server.start port
let _ = Unix.sleep 3

let misc = [
  "link", [
    Test_link.test "redis" Test_redis.link;
    Test_link.test "redis-cluster" Test_cluster.link;
  ]
]

let _ = at_exit (fun () ->
  Hiredis.Shell.Server.stop server;
  Test_cluster.stop Test_cluster.servers)

let () =
  let client = Hiredis.Client.connect ~port "127.0.0.1" in
  if Hiredis.Client.run client [| "PING" |] <> Hiredis_value.Nil then
  Test_store.run "irmin-redis" ~misc [
    `Quick , Test_redis.suite;
    `Quick, Test_cluster.suite;
  ]
