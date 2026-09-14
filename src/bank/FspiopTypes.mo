/// FspiopTypes.mo: FSPIOP (Mojaloop Open API for FSP Interoperability, v1.1) on the settlement layer
///: the types.
///
/// The adapter is not a second core. A rail's participants are named by their FSP ids; a
/// `POST /transfers` is a settlement transfer prepared with the `transferId` as its reference and
/// reserved in the same message (§14.2), carrying the ILP `condition`; the payee's
/// `PUT /transfers/{ID}` with the `fulfilment` posts it once SHA-256(fulfilment) equals the
/// condition; prepare/fulfil is reserve/post, the cryptography the one check. Quotes, parties and
/// transaction requests are the scheme's routing: validated, recorded, and forwarded to the
/// destination FSP as callbacks the relay delivers; the participant directory (K6) and the callback
/// endpoints (the reference's 58 endpoint types, `ENDPOINT_TYPES`) are recorded configuration.
///
/// Every request is one block (`#requestHandled`): the method, the path, the source and destination,
/// the hash of the body, the status answered, the error code when one, the callbacks produced.

module {

  public type FspId = Text;

  public type Request = { method : Text; path : Text; headers : [(Text, Text)]; body : Text };
  /// What the relay delivers to the destination FSP: the callback the scheme requires (the forwarded
  /// request, the `PUT` of a result, an `/error`), with the registered URL when one is known.
  public type Callback = { destination : FspId; method : Text; path : Text; body : Text; url : ?Text };
  public type Response = { status : Nat; body : Text; callbacks : [Callback] };

  public type FspiopEvent = {
    /// A participant of the rail's scheme named by its FSP id, with its callback endpoints (type, URL).
    #participantDeclared : { rail : Text; participant : Nat; fspId : FspId; endpoints : [(Text, Text)] };
    /// The account-lookup oracle: a party identifier held by an FSP.
    #partyRegistered : { rail : Text; idType : Text; id : Text; subId : ?Text; fspId : FspId; currency : ?Text };
    #partyDeregistered : { rail : Text; idType : Text; id : Text; subId : ?Text };
    /// A quote request recorded on its way to the payee, and the payee's answer with the condition.
    #quoteReceived : { rail : Text; quoteId : Text; transactionId : Text; payerFsp : FspId; payeeFsp : FspId; amount : Nat; currency : Text; amountType : Text; expiration : ?Text };
    #quoteAnswered : { rail : Text; quoteId : Text; transferAmount : Nat; currency : Text; condition : Blob; ilpPacketHash : Blob; expiration : Text };
    /// The FSPIOP transfer bound to its settlement transfer, with the ILP condition the fulfilment must hash to.
    #transferPrepared : { rail : Text; transferId : Text; transfer : Nat; condition : Blob; expiration : Text; ilpPacketHash : Blob };
    #transferFulfilled : { rail : Text; transferId : Text; transfer : Nat; fulfilment : Blob; completedAt : Text };
    #transferAborted : { rail : Text; transferId : Text; transfer : Nat; errorCode : Text; reason : Text };
    #requestHandled : { rail : Text; method : Text; path : Text; source : ?FspId; destination : ?FspId; hash : Blob; status : Nat; errorCode : ?Text; callbacks : Nat };
  };

  public type FspiopError = {
    #UnknownRail : { rail : Text };
    #UnknownParticipant : { participant : Nat };
    #FspIdTaken : { rail : Text; fspId : FspId };
    #InvalidEndpoint : { reason : Text };
  };

  /// The FSPIOP error codes this adapter answers with (Mojaloop central-services-error-handling).
  public let ERRORS : [(Text, Text, Nat)] = [
    ("2002", "Not implemented", 501),
    ("3000", "Generic client error", 400),
    ("3001", "Unacceptable version requested", 406),
    ("3002", "Unknown URI", 404),
    ("3003", "Add Party information error", 400),
    ("3100", "Generic validation error", 400),
    ("3101", "Malformed syntax", 400),
    ("3102", "Missing mandatory element", 400),
    ("3103", "Too many elements", 400),
    ("3104", "Too large payload", 400),
    ("3200", "Generic ID not found", 400),
    ("3201", "Destination FSP Error", 400),
    ("3202", "Payer FSP ID not found", 400),
    ("3203", "Payee FSP ID not found", 400),
    ("3204", "Party not found", 400),
    ("3205", "Quote ID not found", 400),
    ("3208", "Transfer ID not found", 400),
    ("3300", "Generic expired error", 400),
    ("3303", "Transfer expired", 400),
    ("4001", "Payer FSP insufficient liquidity", 400),
    ("5105", "Payee FSP rejected transaction", 400),
  ];

  public func errorText(code : Text) : Text { for ((c, t, _) in ERRORS.vals()) { if (c == code) return t }; "Error" };
  public func errorStatus(code : Text) : Nat { for ((c, _, s) in ERRORS.vals()) { if (c == code) return s }; 400 };

  /// The party identifier types of FSPIOP v1.1.
  public let PARTY_ID_TYPES : [Text] = ["MSISDN", "EMAIL", "PERSONAL_ID", "BUSINESS", "DEVICE", "ACCOUNT_ID", "IBAN", "ALIAS"];

  /// The endpoint types of the reference (central-ledger v20.0.0 `endpointType` seed): 58 distinct names
  /// (the seed lists `TP_CB_URL_CONSENT_REQUEST_PUT_ERROR` twice, so it has 59 rows).
  public let ENDPOINT_TYPES : [Text] = [
    "ALARM_NOTIFICATION_URL", "ALARM_NOTIFICATION_TOPIC", "FSPIOP_CALLBACK_URL_TRANSFER_POST", "FSPIOP_CALLBACK_URL_TRANSFER_PUT", "FSPIOP_CALLBACK_URL_TRANSFER_ERROR",
    "NET_DEBIT_CAP_THRESHOLD_BREACH_EMAIL", "NET_DEBIT_CAP_ADJUSTMENT_EMAIL", "SETTLEMENT_TRANSFER_POSITION_CHANGE_EMAIL", "FSPIOP_CALLBACK_URL_PARTICIPANT_PUT",
    "FSPIOP_CALLBACK_URL_PARTICIPANT_SUB_ID_PUT", "FSPIOP_CALLBACK_URL_PARTICIPANT_PUT_ERROR", "FSPIOP_CALLBACK_URL_PARTICIPANT_SUB_ID_PUT_ERROR", "FSPIOP_CALLBACK_URL_PARTICIPANT_DELETE",
    "FSPIOP_CALLBACK_URL_PARTICIPANT_SUB_ID_DELETE", "FSPIOP_CALLBACK_URL_PARTICIPANT_BATCH_PUT", "FSPIOP_CALLBACK_URL_PARTICIPANT_BATCH_PUT_ERROR", "FSPIOP_CALLBACK_URL_PARTIES_GET",
    "FSPIOP_CALLBACK_URL_PARTIES_SUB_ID_GET", "FSPIOP_CALLBACK_URL_PARTIES_PUT", "FSPIOP_CALLBACK_URL_PARTIES_SUB_ID_PUT", "FSPIOP_CALLBACK_URL_PARTIES_PUT_ERROR",
    "FSPIOP_CALLBACK_URL_PARTIES_SUB_ID_PUT_ERROR", "FSPIOP_CALLBACK_URL_QUOTES", "FSPIOP_CALLBACK_URL_BULK_TRANSFER_POST", "FSPIOP_CALLBACK_URL_BULK_TRANSFER_PUT",
    "FSPIOP_CALLBACK_URL_BULK_TRANSFER_ERROR", "FSPIOP_CALLBACK_URL_AUTHORIZATIONS", "FSPIOP_CALLBACK_URL_TRX_REQ_SERVICE", "FSPIOP_CALLBACK_URL_BULK_QUOTES",
    "TP_CB_URL_TRANSACTION_REQUEST_GET", "TP_CB_URL_TRANSACTION_REQUEST_POST", "TP_CB_URL_TRANSACTION_REQUEST_PUT", "TP_CB_URL_TRANSACTION_REQUEST_PUT_ERROR",
    "TP_CB_URL_TRANSACTION_REQUEST_PATCH", "TP_CB_URL_TRANSACTION_REQUEST_AUTH_POST", "TP_CB_URL_TRANSACTION_REQUEST_AUTH_PUT", "TP_CB_URL_TRANSACTION_REQUEST_AUTH_PUT_ERROR",
    "TP_CB_URL_TRANSACTION_REQUEST_VERIFY_POST", "TP_CB_URL_TRANSACTION_REQUEST_VERIFY_PUT", "TP_CB_URL_TRANSACTION_REQUEST_VERIFY_PUT_ERROR", "TP_CB_URL_CONSENT_REQUEST_POST",
    "TP_CB_URL_CONSENT_REQUEST_PUT", "TP_CB_URL_CONSENT_REQUEST_PUT_ERROR", "TP_CB_URL_CONSENT_REQUEST_PATCH", "TP_CB_URL_CREATE_CREDENTIAL_POST", "TP_CB_URL_CONSENT_POST",
    "TP_CB_URL_CONSENT_GET", "TP_CB_URL_CONSENT_PUT", "TP_CB_URL_CONSENT_PATCH", "TP_CB_URL_CONSENT_PUT_ERROR", "TP_CB_URL_CONSENT_GENERATE_CHALLENGE_POST",
    "TP_CB_URL_CONSENT_GENERATE_CHALLENGE_PUT_ERROR", "TP_CB_URL_ACCOUNTS_GET", "TP_CB_URL_ACCOUNTS_PUT", "TP_CB_URL_ACCOUNTS_PUT_ERROR", "TP_CB_URL_SERVICES_GET",
    "TP_CB_URL_SERVICES_PUT", "TP_CB_URL_SERVICES_PUT_ERROR",
  ];

  /// The operations this adapter implements, as (method, path template of FspiopProfiles.OPERATIONS);
  /// every other operation of the specification answers 2002 (Not implemented) with the error shape,
  /// a path outside the specification 3002 (Unknown URI).
  public let IMPLEMENTED : [(Text, Text)] = [
    ("POST", "/participants/{Type}/{ID}"), ("GET", "/participants/{Type}/{ID}"), ("DELETE", "/participants/{Type}/{ID}"),
    ("POST", "/participants/{Type}/{ID}/{SubId}"), ("GET", "/participants/{Type}/{ID}/{SubId}"), ("DELETE", "/participants/{Type}/{ID}/{SubId}"),
    ("GET", "/parties/{Type}/{ID}"), ("PUT", "/parties/{Type}/{ID}"), ("PUT", "/parties/{Type}/{ID}/error"),
    ("GET", "/parties/{Type}/{ID}/{SubId}"), ("PUT", "/parties/{Type}/{ID}/{SubId}"), ("PUT", "/parties/{Type}/{ID}/{SubId}/error"),
    ("POST", "/quotes"), ("GET", "/quotes/{ID}"), ("PUT", "/quotes/{ID}"), ("PUT", "/quotes/{ID}/error"),
    ("POST", "/transactionRequests"), ("GET", "/transactionRequests/{ID}"), ("PUT", "/transactionRequests/{ID}"), ("PUT", "/transactionRequests/{ID}/error"),
    ("POST", "/transfers"), ("GET", "/transfers/{ID}"), ("PUT", "/transfers/{ID}"), ("PUT", "/transfers/{ID}/error"),
  ];
}
