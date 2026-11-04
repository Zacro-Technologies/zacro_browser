  // Checked idempotent legacy import. The journal stores identifiers/hashes,
  // not another URL/title copy after native deletion. A retained missing visit
  // is a tombstone, never permission to reinsert it on a lost-ack retry.
  bool FindNativeLegacyImport(const NativeHistoryLegacyInput& input,
      std::optional<NativeHistoryLegacyResult>* result);
  bool RecordNativeLegacyImport(const NativeHistoryLegacyInput& input, VisitID visit);
  bool AcknowledgeNativeLegacyImports(
      const std::vector<std::pair<std::string, std::string>>& identities);
