val config:
  ?config:Irmin.Private.Conf.t ->
  ?root:string ->
  ?port:int ->
  ?nclients:int ->
  string ->
  Irmin.config
val info :
  ?author:string ->
  ('a, Format.formatter, unit, Irmin.Info.f) format4 ->
  'a
module AO: Irmin.AO_MAKER
module Link: Irmin.LINK_MAKER
module RW: Irmin.RW_MAKER
module Make: Irmin.S_MAKER
module KV: Irmin.KV_MAKER

