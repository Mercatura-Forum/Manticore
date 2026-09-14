/// OriginationTypes.mo; an application for credit, from the ask to the drawing, every step a block (origination and underwriting).
///
/// An application is an object on the bank log: opened for a party (an existing customer) or for a prospect
/// (no party yet; the onboarding that fulfils it names the application and becomes its party), it moves
/// through capture, affordability, the bureau, scoring, underwriting, the offer and its acceptance,
/// documentation, and the drawing. Nothing in it decides in the dark: the affordability rules and the
/// scorecard are recorded data with versions and every evaluation names the version it used; the bureau's
/// report is a payload signed by a registered bureau key whose body stays off the chain and whose hash is on
/// it; the applicant's acceptance is a WebAuthn assertion; a P-256 signature over the offer's hash as the
/// challenge; verified in the contract against the passkey the party registered; the credit decision is
/// four eyes; the amounts are the only figures in blocks and every identity is a commitment. Facts
/// about the applicant are amounts (income, obligations) and commitments; no name, no identifier, no document
/// content ever enters a block.

import PT "PartyTypes";
import PayT "PaymentsTypes";

module {

  public type Day = Nat;
  public type ApplicationId = Nat;   // the bank block index of #applicationOpened

  public type Stage = {
    #capture; #assessed; #scored; #underwritten; #offered; #accepted; #documented; #fulfilled;
    #declined; #withdrawn; #expired;
  };

  public func stageText(s : Stage) : Text {
    switch (s) {
      case (#capture) "capture"; case (#assessed) "assessed"; case (#scored) "scored"; case (#underwritten) "underwritten";
      case (#offered) "offered"; case (#accepted) "accepted"; case (#documented) "documented"; case (#fulfilled) "fulfilled";
      case (#declined) "declined"; case (#withdrawn) "withdrawn"; case (#expired) "expired";
    }
  };
  public func stageCode(s : Stage) : Nat8 {
    switch (s) {
      case (#capture) 0; case (#assessed) 1; case (#scored) 2; case (#underwritten) 3; case (#offered) 4; case (#accepted) 5;
      case (#documented) 6; case (#fulfilled) 7; case (#declined) 8; case (#withdrawn) 9; case (#expired) 10;
    }
  };
  public func stageOfCode(c : Nat8) : ?Stage {
    switch (c) {
      case 0 ?#capture; case 1 ?#assessed; case 2 ?#scored; case 3 ?#underwritten; case 4 ?#offered; case 5 ?#accepted;
      case 6 ?#documented; case 7 ?#fulfilled; case 8 ?#declined; case 9 ?#withdrawn; case 10 ?#expired; case _ null;
    }
  };
  public let STAGES : Nat = 11;
  /// A terminal stage admits no further act.
  public func terminal(s : Stage) : Bool {
    switch (s) { case (#fulfilled or #declined or #withdrawn or #expired) true; case (_) false }
  };

  /// What is asked for. The product names the loan product the facility will be opened under; its
  /// currency is the product's.
  public type Request = { product : Text; amount : Nat; currency : Text; termDays : Nat; purpose : Text };

  /// The recorded facts an evaluation reads: amounts in minor units and a count, never identities.
  public type Facts = { income : Nat; obligations : Nat; proposedInstalment : Nat; dependants : Nat };

  // ── the models, as data ──

  public type RuleKind = {
    #maxDebtServiceRatioBps : Nat;    // fires when (obligations + proposedInstalment) · 10000 > bps · income
    #minResidualIncome : Nat;         // fires when income − obligations − proposedInstalment < amount · (dependants + 1)
    #maxTermDays : Nat;               // fires when the requested term exceeds it
    #maxAmount : Nat;                 // fires when the requested amount exceeds it
    #minIncome : Nat;                 // fires when income is below it
  };
  public type Rule = { id : Text; kind : RuleKind; onFail : { #fail; #refer } };
  public type AffordabilityModel = { id : Text; version : Nat; rules : [Rule] };
  /// The rule ids that fired: a failing rule fails the application, a referring one refers it; fail wins.
  public type Verdict = { #pass; #fail : [Text]; #refer : [Text] };

  /// A scorecard: points per band of each attribute, and the cut-offs the total is read against. A band
  /// is `lo ≤ value ≤ hi` (`hi` absent: unbounded); the first band that holds the value scores; a value no
  /// band holds scores nothing. A bureau attribute with no report recorded scores nothing.
  public type Attribute = { #income; #obligationsRatioBps; #bureauScore; #bureauFlags; #termDays; #amount };
  public type Band = { lo : Nat; hi : ?Nat; points : Nat };
  public type Scorecard = { id : Text; version : Nat; attributes : [(Attribute, [Band])]; declineBelow : Nat; referBelow : Nat };
  public type ScoreBand = { #approve; #refer; #decline };

  /// The bureau's report as the contract keeps it: the figures, and the hash of the body that stays outside.
  public type BureauReport = { bureau : Text; score : Nat; flags : [Text]; reportHash : Blob; reportedOn : Day };

  public type Decision = {
    #approve : { amount : Nat; termDays : Nat; rateBps : Nat; conditions : [Text] };
    #decline : { reasons : [Text] };
    #refer : { to : Text };
  };

  public type OfferTerms = { amount : Nat; termDays : Nat; rateBps : Nat; product : Text; currency : Text; conditions : [Text] };

  /// A WebAuthn assertion, as the client produces it: the authenticator data, the client data JSON and the
  /// DER-encoded ECDSA P-256 signature over SHA-256(authenticatorData ‖ SHA-256(clientDataJSON)).
  public type PasskeyAssertion = { credentialId : Blob; authenticatorData : Blob; clientDataJSON : Blob; signature : Blob };

  public type DocumentKind = { #facilityAgreement; #collateralPledge; #insurance; #guarantee; #other : Text };

  public type Policy = {
    /// The relying party the passkeys are bound to, and the origin the client data must name.
    rpId : Text;
    origin : Text;
    offerValidityDays : Nat;
    /// The bureaus the bank accepts reports from, with the scheme and key each signs with.
    bureaus : [(Text, PayT.SignatureScheme, Blob)];
  };

  public type OriginationEvent = {
    #policySet : Policy;
    #affordabilityModelSet : AffordabilityModel;
    #scorecardSet : Scorecard;
    #passkeyRegistered : { party : PT.PartyId; credentialId : Blob; publicKeySpki : Blob };
    #applicationOpened : { party : ?PT.PartyId; book : Text; request : Request; channel : Text; day : Day };
    #dataRecorded : { application : ApplicationId; facts : Facts; commitments : [(Text, PT.Commitment)] };
    #affordabilityAssessed : { application : ApplicationId; model : Text; version : Nat; verdict : Verdict };
    #bureauRequested : { application : ApplicationId; bureau : Text; consentCommit : PT.Commitment; day : Day };
    #bureauRecorded : { application : ApplicationId; report : BureauReport };
    #scored : { application : ApplicationId; scorecard : Text; version : Nat; points : Nat; band : ScoreBand };
    #underwritten : { application : ApplicationId; decision : Decision; rationale : Text; overrode : Bool };
    #offerIssued : { application : ApplicationId; terms : OfferTerms; offerHash : Blob; expiresAt : Day };
    #offerAccepted : { application : ApplicationId; credentialId : Blob; assertionHash : Blob; day : Day };
    #offerDeclined : { application : ApplicationId; day : Day };
    #offerExpired : { application : ApplicationId; day : Day };
    #documentRecorded : { application : ApplicationId; kind : DocumentKind; sha256 : Blob; signed : Bool };
    #conditionsMet : { application : ApplicationId; conditions : [Text]; outstanding : Nat };
    #documentationComplete : { application : ApplicationId; day : Day };
    #prospectOnboarded : { application : ApplicationId; party : PT.PartyId };
    #fulfilled : { application : ApplicationId; party : PT.PartyId; account : Nat; day : Day };
    #withdrawn : { application : ApplicationId; reason : Text; day : Day };
  };

  public type OriginationError = {
    #UnknownApplication : { application : ApplicationId };
    #WrongStage : { application : ApplicationId; stage : Text; wanted : Text };
    #NoPolicy;
    #NoModel : { kind : Text };
    #InvalidModel : { reason : Text };
    #UnknownBureau : { bureau : Text };
    #BureauNotRequested : { application : ApplicationId; bureau : Text };
    #SignatureInvalid : { bureau : Text };
    #UnknownPasskey : { party : PT.PartyId; credentialId : Blob };
    #PasskeyExists : { party : PT.PartyId; credentialId : Blob };
    #AssertionRefused : { reason : Text };
    #OfferExpired : { application : ApplicationId; expiresAt : Day; today : Day };
    #OfferMismatch : { reason : Text };
    #DecisionAgainstBand : { band : Text; reason : Text };
    #ConditionsOutstanding : { application : ApplicationId; outstanding : Nat };
    #UnknownCondition : { application : ApplicationId; condition : Text };
    #NoParty : { application : ApplicationId };
    #PartyMismatch : { application : ApplicationId };
    #InvalidRequest : { reason : Text };
  };

  public type ApplicationView = {
    id : ApplicationId;
    party : ?PT.PartyId;
    book : Text;
    stage : Stage;
    product : Text;
    currency : Text;
    amount : Nat;
    termDays : Nat;
    facts : ?Facts;
    verdict : ?{ #pass; #fail; #refer };
    bureauScore : ?Nat;
    points : ?Nat;
    band : ?ScoreBand;
    approved : ?{ amount : Nat; termDays : Nat; rateBps : Nat };
    offerHash : ?Blob;
    offerExpiresAt : ?Day;
    documents : Nat;
    conditions : Nat;
    conditionsMet : Nat;
    account : ?Nat;
    openedDay : Day;
    openedBlock : Nat;
    lastBlock : Nat;
  };
}
