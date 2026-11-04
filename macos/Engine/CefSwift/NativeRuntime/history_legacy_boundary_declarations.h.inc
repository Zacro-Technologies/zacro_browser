  std::optional<std::string> CreateNativeLegacyBoundary();
  std::optional<std::vector<std::string>> ReadNativeLegacyBoundaries();
  bool FinalizeNativeLegacyBoundary(const std::string& lease, bool completed_initial);
  bool NativeLegacyInputAllowed(const NativeHistoryLegacyInput& input, bool* allowed);
  bool RecordNativeLegacyDeletion(const std::optional<GURL>& url, base::Time begin,
      base::Time end, bool inclusive_end = false, bool allow_reset = false);
  bool RecordNativeLegacyDeletions(const std::vector<NativeHistoryDeletionScope>& scopes,
      bool allow_reset = false);
