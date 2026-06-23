import '../bridge/bridge_generated.dart/core.dart' show TxAction, TxActionKind;

/// Convenience builders for the generated [TxAction] (which requires every
/// field). Unused fields are empty strings, matching how `dispatch_action`
/// reads them on the Rust side.

TxAction sendAction(String to, String amountPlanck) => TxAction(
      kind: TxActionKind.send,
      name: '',
      to: to,
      amountPlanck: amountPlanck,
      recipient: '',
    );

TxAction registerNameAction(String name) => TxAction(
      kind: TxActionKind.registerName,
      name: name,
      to: '',
      amountPlanck: '',
      recipient: '',
    );

TxAction transferNameAction(String to) => TxAction(
      kind: TxActionKind.transferName,
      name: '',
      to: to,
      amountPlanck: '',
      recipient: '',
    );

const TxAction releaseNameAction = TxAction(
  kind: TxActionKind.releaseName,
  name: '',
  to: '',
  amountPlanck: '',
  recipient: '',
);

const TxAction renewNameAction = TxAction(
  kind: TxActionKind.renewName,
  name: '',
  to: '',
  amountPlanck: '',
  recipient: '',
);

TxAction buyNameAction(String name) => TxAction(
      kind: TxActionKind.buyName,
      name: name,
      to: '',
      amountPlanck: '',
      recipient: '',
    );

TxAction buyNameForAction(String name, String recipient) => TxAction(
      kind: TxActionKind.buyNameFor,
      name: name,
      to: '',
      amountPlanck: '',
      recipient: recipient,
    );
