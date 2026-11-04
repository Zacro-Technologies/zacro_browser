  bool RetainNativeMirrorVisit(const NativeHistoryRetention& identity);
  bool ReplaceNativeMirrorRetention(const std::vector<NativeHistoryRetention>& identities);
  bool ReadNativeExpiringVisits(base::Time begin_time, base::Time end_time,
      int max_visits, std::optional<ui::PageTransition> transition, VisitVector* visits);
  std::optional<std::pair<int64_t, int>> NativeHistoryRetentionStatus();
