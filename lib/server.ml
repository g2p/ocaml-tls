open Core
open Flow

let answer_client_finished (sp : security_parameters) (packets : Cstruct.t list) (buf : Cstruct.t) (raw : Cstruct.t)  =
  let msgs = Utils.cs_appends packets in
  let computed = Crypto.finished sp.master_secret "client finished" msgs in
  assert (Utils.cs_eq computed buf);
  Printf.printf "received good handshake finished\n";
  let my_checksum = Crypto.finished sp.master_secret "server finished" (msgs <> raw) in
  let send = Writer.assemble_handshake (Finished my_checksum) in
  (`Established, [`Record (Packet.HANDSHAKE, send)], `Pass)

let answer_client_key_exchange (sp : security_parameters) (packets : Cstruct.t list) (kex : Cstruct.t) (raw : Cstruct.t) =
  let premastersecret =
    match Ciphersuite.ciphersuite_kex sp.ciphersuite with
    | Ciphersuite.RSA ->
       Crypto.decryptRSA_unpadPKCS 48 (Crypto_utils.get_key "server.key") kex
    | Ciphersuite.DHE_RSA ->
       (* we assume explicit communication here, not a client certificate *)
       let p = match sp.dh_p with
         | Some x -> x
         | None -> assert false
       in
       let g = match sp.dh_g with
         | Some x -> x
         | None -> assert false
       in
       let sec = match sp.dh_secret with
         | Some x -> x
         | None -> assert false
       in
       Crypto.computeDH p g sec kex
    | _ -> assert false
  in
  let mastersecret = Crypto.generate_master_secret premastersecret (sp.client_random <> sp.server_random) in
  Printf.printf "master secret\n";
  Cstruct.hexdump mastersecret;

  let key, iv, mac = Ciphersuite.ciphersuite_cipher_mac_length sp.ciphersuite in
  let keyblocklength =  2 * key + 2 * mac + 2 * iv in
  let keyblock = Crypto.key_block keyblocklength mastersecret (sp.server_random <> sp.client_random) in

  let c_mac, off = (Cstruct.sub keyblock 0 mac, mac) in
  let s_mac, off = (Cstruct.sub keyblock off mac, off + mac) in
  let c_key, off = (Cstruct.sub keyblock off key, off + key) in
  let s_key, off = (Cstruct.sub keyblock off key, off + key) in
  let c_iv, off = (Cstruct.sub keyblock off iv, off + iv) in
  let s_iv = Cstruct.sub keyblock off iv in

  let mac = Ciphersuite.ciphersuite_mac sp.ciphersuite in
  let sequence = 0L in
  let cipher = Ciphersuite.ciphersuite_cipher sp.ciphersuite in

  let c_stream_cipher, s_stream_cipher =
    match cipher with
    | Ciphersuite.RC4_128 ->
       let ccipher = new Cryptokit.Stream.arcfour (Cstruct.copy c_key 0 key) in
       let scipher = new Cryptokit.Stream.arcfour (Cstruct.copy s_key 0 key) in
       (Some ccipher, Some scipher)
    | _ -> (None, None)
  in

  let c_context =
    { stream_cipher = c_stream_cipher ;
      cipher_secret = c_key ;
      cipher_iv = c_iv ;
      mac_secret = c_mac ;
      cipher ; mac ; sequence } in
  let s_context =
    { stream_cipher = s_stream_cipher ;
      cipher_secret = s_key ;
      cipher_iv = s_iv ;
      mac_secret = s_mac ;
      cipher ; mac ; sequence }
  in
  let params = { sp with master_secret = mastersecret } in
  (`KeysExchanged (`Crypted s_context, `Crypted c_context, params, packets @ [raw]), [], `Pass)

let answer_client_hello (ch : client_hello) raw =
(*    let cipher = Ciphersuite.TLS_RSA_WITH_3DES_EDE_CBC_SHA in *)
(*    let cipher = Ciphersuite.TLS_RSA_WITH_RC4_128_MD5 in *)
(*    let cipher = Ciphersuite.TLS_RSA_WITH_RC4_128_SHA in *)
  let cipher = Ciphersuite.TLS_DHE_RSA_WITH_3DES_EDE_CBC_SHA in
  assert (List.mem cipher ch.ciphersuites);
  (* TODO : real random *)
  let r = Cstruct.create 32 in
  let params = { entity             = Server ;
                 ciphersuite        = cipher ;
                 master_secret      = Cstruct.create 0 ;
                 client_random      = ch.random ;
                 server_random      = r ;
                 dh_p               = None ;
                 dh_g               = None ;
                 dh_secret          = None ;
                 server_certificate = None }
  in
  let server_hello : server_hello =
    { version      = (3, 1) ;
      random       = r ;
      sessionid    = None ;
      ciphersuites = cipher ;
      extensions   = [] } in
  let bufs = [Writer.assemble_handshake (ServerHello server_hello)] in
  let kex = Ciphersuite.ciphersuite_kex cipher in
  let bufs', params' =
    if Ciphersuite.needs_certificate kex then
      let pem = Crypto_utils.read_pem_file "server.pem" in
      let cert = Crypto_utils.pem_to_cstruct pem in
      let asn = Crypto_utils.pem_to_cert pem in
      (bufs @ [Writer.assemble_handshake (Certificate [cert])],
       { params with server_certificate = Some asn })
    else
      (bufs, params)
  in
  let bufs'', params'' =
    if Ciphersuite.needs_server_kex kex then
      begin
        match kex with
        | Ciphersuite.DHE_RSA ->
           let dh_p, dh_g, dh_Ys, priv = Crypto.generateDH 1024 in
           let params'' = { params' with dh_p = Some dh_p ; dh_g = Some dh_g ; dh_secret = Some priv } in
           let dhparams = { dh_p ; dh_g ; dh_Ys } in
           let written = Writer.assemble_dh_parameters dhparams in
           Printf.printf "written";
           Cstruct.hexdump written;
           let data = (params''.client_random <> params''.server_random) <> written in
           let md5signature = Crypto.md5 data in
           let shasignature = Crypto.sha data in
           let signing = md5signature <> shasignature in
           Printf.printf "signing";
           Cstruct.hexdump signing;
           let sign = Crypto.padPKCS1_and_signRSA 128 (Crypto_utils.get_key "server.key") signing in
           let kex = DiffieHellman (written, sign) in
           (bufs' @ [Writer.assemble_handshake (ServerKeyExchange kex)], params'')
        | _ -> assert false
      end
    else
      (bufs', params')
  in
  (* server hello done! *)
  let hello_done = Writer.assemble_handshake ServerHelloDone in
  let packets = bufs'' @ [hello_done] in
  (`Handshaking (params'', raw :: packets),
   List.map (fun e -> `Record (Packet.HANDSHAKE, e)) packets,
   `Pass)

let handle_record
: tls_internal_state -> content_type -> Cstruct.t
  -> (tls_internal_state * rec_resp list * dec_resp)
= fun is ct buf ->
  Printf.printf "HANDLE_RECORD (in state %s) %s\n"
                (state_to_string is)
                (Packet.content_type_to_string ct);
  match ct with
  | Packet.ALERT ->
     let al = Reader.parse_alert buf in
     Printf.printf "ALERT: %s" (Printer.alert_to_string al);
     (is, [], `Pass)
  | Packet.APPLICATION_DATA ->
     Printf.printf "APPLICATION DATA";
     Cstruct.hexdump buf;
     (is, [], `Pass)
  | Packet.CHANGE_CIPHER_SPEC ->
     begin
       match is with
       | `KeysExchanged (enc, dec, _, _) ->
          let ccs = Cstruct.create 1 in
          Cstruct.set_uint8 ccs 0 1;
          (is,
           [`Record (Packet.CHANGE_CIPHER_SPEC, ccs); `Change_enc enc],
           `Change_dec dec)
       | _ -> assert false
     end
  | Packet.HANDSHAKE ->
     begin
       let handshake = Reader.parse_handshake buf in
       Printf.printf "HANDSHAKE: %s" (Printer.handshake_to_string handshake);
       Cstruct.hexdump buf;
       match (is, handshake) with
       | `Initial, ClientHello ch ->
            answer_client_hello ch buf
       | `Handshaking (p, bs), ClientKeyExchange kex ->
            answer_client_key_exchange p bs kex buf
       | `KeysExchanged (_, _, p, bs), Finished fin ->
            answer_client_finished p bs fin buf
       | `Established, ClientHello ch -> (* key renegotiation *)
            answer_client_hello ch buf
       | _, _-> assert false
     end
  | _ -> assert false

let handle_raw_record state (hdr, buf) =
  let (dec_st, dec) = decrypt state.decryptor hdr.content_type buf in
  let (machina, items, dec_cmd) =
    handle_record state.machina hdr.content_type dec in
  let (encryptor, encs) =
    let rec loop st = function
      | [] -> (st, [])
      | `Change_enc st'   :: xs -> loop st' xs
      | `Record (ty, buf) :: xs ->
          let (st1, enc ) = encrypt st ty buf in
          let (st2, rest) = loop st1 xs in
          (st2, (ty, enc) :: rest)
    in
    loop state.encryptor items in
  let decryptor = match dec_cmd with
    | `Change_dec dec -> dec
    | `Pass           -> dec_st in
  ({ machina ; encryptor ; decryptor }, encs)

let handle_tls : state -> Cstruct.t -> state * Cstruct.t
= fun state buf ->
  let in_records = separate_records buf in
  let (state', out_records) =
    let rec loop st = function
      | []    -> (st, [])
      | r::rs ->
          let (st1, raw_rs ) = handle_raw_record st r in
          let (st2, raw_rs') = loop st1 rs in
          (st2, raw_rs @ raw_rs') in
    loop state in_records in
  let buf' = assemble_records out_records in
  (state', buf')
