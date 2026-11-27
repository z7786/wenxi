import 'rule_network_audit.dart';

void main() => runRuleNetworkAudit(
  flag: 'ASTERLINK_LATENCY_AUDIT',
  reportDirectory: 'rule-latency-20261116',
  defaultTag: 'app',
);
