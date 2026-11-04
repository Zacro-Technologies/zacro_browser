// Native browser ownership, supplied only for explicitly registered public
// WebContents. The renderer, History API and portable imports cannot set it.
struct NativeHistoryDocument {
  std::string document_token;
  std::string producer_epoch;
  std::string logical_id;
  std::string event_id;
  // Electron Library records full-document commits; native SPA visits retain
  // their real identity without fabricating another Library row. Explicit
  // Peek promotion may publish its exact current SPA event.
  bool library_visit = true;
  bool publish = false;  // Only an authoritative adopted Core tab is published.
  // Unadopted ordinary popups retain every commit. Only a transient Peek may
  // replace its previous unpublished handoff with its current document visit.
  bool preview = false;
};

