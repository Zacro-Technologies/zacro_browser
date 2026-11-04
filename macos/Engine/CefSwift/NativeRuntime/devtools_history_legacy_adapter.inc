bool ZacroHistoryLegacyHash(const std::string& value) {
  return value.size() == 64 && std::ranges::all_of(value, [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}

void ZacroHistoryContext::Legacy(const std::string& method, const base::DictValue& params,
                                 ZacroHistoryReply reply) {
  if (method == "Zacro.createLegacyHistoryBoundary" || method == "Zacro.legacyHistoryBoundaries" ||
      method == "Zacro.finalizeLegacyHistoryBoundary") {
    using Action = ZacroHistoryLegacyBoundaryTask::Action;
    const auto* lease = params.FindString("leaseID");
    const auto completed = params.FindBool("completedInitial");
    if (method == "Zacro.finalizeLegacyHistoryBoundary" && (!lease || !ZacroHistoryUUID(*lease) || !completed)) {
      std::move(reply).Run({}, "Invalid legacy migration boundary."); return;
    }
    const auto action = method == "Zacro.createLegacyHistoryBoundary" ? Action::kCreate :
        method == "Zacro.legacyHistoryBoundaries" ? Action::kList : Action::kFinalize;
    const auto request = Queue(std::move(reply));
    service_->ScheduleDBTask(FROM_HERE, std::make_unique<ZacroHistoryLegacyBoundaryTask>(action,
        lease ? *lease : "", completed.value_or(false), base::BindOnce(
        [](base::WeakPtr<ZacroHistoryContext> self, std::string request, Action action,
           ZacroHistoryLegacyBoundaryTask::Result result) {
          if (!self) return;
          if (!result || (action == Action::kCreate && result->size() != 1)) {
            self->Complete(request, {}, "The native legacy migration boundary is unavailable."); return;
          }
          if (action == Action::kCreate) {
            self->Complete(request, base::DictValue().Set("leaseID", result->front()), {});
          } else if (action == Action::kList) {
            base::ListValue leases; for (const auto& value : *result) leases.Append(value);
            self->Complete(request, base::DictValue().Set("leases", std::move(leases)), {});
          } else self->MutationComplete(request, true);
        }, weak_.GetWeakPtr(), request, action)), &tracker_); return;
  }
  if (method == "Zacro.importLegacyHistory") {
    const auto* records = params.FindList("inputs");
    auto encoded = records ? base::WriteJson(*records) : std::nullopt;
    if (!records || records->empty() || records->size() > 512 || !encoded || encoded->size() > 512 * 1024) {
      std::move(reply).Run({}, "Invalid or excessive legacy history import."); return;
    }
    std::set<std::string> unique;
    std::vector<history::NativeHistoryLegacyInput> inputs;
    for (const auto& record : *records) {
      const auto* data = record.GetIfDict();
      const auto* id = data ? data->FindString("importID") : nullptr;
      const auto* url = data ? data->FindString("url") : nullptr;
      const auto* time = data ? data->FindString("timeMicroseconds") : nullptr;
      const auto* title = data ? data->FindString("title") : nullptr;
      const auto* boundary = data ? data->FindString("boundaryLeaseID") : nullptr;
      const GURL address(url ? *url : ""); int64_t microseconds = 0;
      if (!id || !ZacroHistoryLegacyHash(*id) || !unique.insert(*id).second || !url || url->size() > 8192 ||
          !address.is_valid() || !address.SchemeIsHTTPOrHTTPS() || address.has_username() || address.has_password() ||
          !time || !ZacroHistoryDecimal(*time, &microseconds) || !title || title->size() > 8192 ||
          !boundary || !ZacroHistoryUUID(*boundary)) {
        std::move(reply).Run({}, "A legacy history import identity is invalid."); return;
      }
      inputs.push_back({*id, address, base::HexEncodeLower(crypto::hash::Sha256(*url)),
          base::Time::FromDeltaSinceWindowsEpoch(base::Microseconds(microseconds)), base::UTF8ToUTF16(*title), *boundary});
    }
    const auto request = Queue(std::move(reply));
    service_->ScheduleDBTask(FROM_HERE, std::make_unique<ZacroHistoryLegacyImportTask>(std::move(inputs),
        base::BindOnce([](base::WeakPtr<ZacroHistoryContext> self, std::string request, base::ListValue inputs,
          ZacroHistoryLegacyImportTask::Result result) {
          if (!self) return;
          if (!result || result->size() != inputs.size()) {
            self->Complete(request, {}, "Chromium could not atomically import and journal the Library visits."); return;
          }
          base::ListValue records;
          for (size_t index = 0; index < result->size(); ++index) {
            const auto& value = (*result)[index];
            // The DB checked the request-address hash stored beside this exact
            // import ID. Attest that request spelling without altering the real
            // GURL/VisitID identity; Foundation and Chromium can canonicalize
            // the same input differently (IDN, escapes and dot segments).
            auto record = base::DictValue().Set("importID", value.import_id).Set("generation", value.generation)
                .Set("boundaryLeaseID", value.boundary_id)
                .Set("sourceAddress", *inputs[index].GetDict().FindString("url"))
                .Set("presence", value.present ? "present" : "absent");
            if (value.present) record.Set("identity", base::DictValue().Set("generation", value.generation)
                .Set("visitID", base::NumberToString(value.visit_id))
                .Set("timeMicroseconds", base::NumberToString(value.time_microseconds))
                .Set("url", value.url).Set("originator", ""));
            records.Append(std::move(record));
          }
          self->Complete(request, base::DictValue().Set("results", std::move(records)), {});
        }, weak_.GetWeakPtr(), request, records->Clone())), &tracker_);
    return;
  }
  if (method == "Zacro.acknowledgeLegacyHistoryImports") {
    const auto* records = params.FindList("entries");
    if (!records || records->size() > 512) { std::move(reply).Run({}, "Invalid legacy history acknowledgement."); return; }
    std::vector<std::pair<std::string, std::string>> values;
    std::set<std::string> unique;
    for (const auto& record : *records) {
      const auto* data = record.GetIfDict();
      const auto* id = data ? data->FindString("importID") : nullptr;
      const auto* generation = data ? data->FindString("generation") : nullptr;
      if (!id || !ZacroHistoryLegacyHash(*id) || !unique.insert(*id).second || !generation ||
          generation->empty() || generation->size() > 64) {
        std::move(reply).Run({}, "Invalid legacy history acknowledgement identity."); return;
      }
      values.emplace_back(*id, *generation);
    }
    const auto request = Queue(std::move(reply));
    service_->ScheduleDBTask(FROM_HERE, std::make_unique<ZacroHistoryLegacyAcknowledgeTask>(std::move(values),
        base::BindOnce([](base::WeakPtr<ZacroHistoryContext> self, std::string request, bool okay) {
          if (self) self->MutationComplete(request, okay);
        }, weak_.GetWeakPtr(), request)), &tracker_); return;
  }
  std::move(reply).Run({}, "Unknown native history operation.");
}


void ZacroHistoryContext::Retention(const std::string& method, const base::DictValue& params,
                                   ZacroHistoryReply reply) {
  if (method == "Zacro.historyRetentionStatus") {
    const auto request = Queue(std::move(reply));
    service_->ScheduleDBTask(FROM_HERE, std::make_unique<ZacroHistoryRetentionStatusTask>(base::BindOnce(
        [](base::WeakPtr<ZacroHistoryContext> self, std::string request,
           ZacroHistoryRetentionStatusTask::Result result) {
          if (!self) return;
          if (!result) { self->Complete(request, {}, "Native retention status is unavailable."); return; }
          self->Complete(request, base::DictValue()
              .Set("automaticExpirationReads", base::NumberToString(result->first))
              .Set("retainedVisits", result->second), {});
        }, weak_.GetWeakPtr(), request)), &tracker_); return;
  }
  const auto* groups = params.FindList("groups");
  auto encoded = groups ? base::WriteJson(*groups) : std::nullopt;
  if (!groups || groups->size() > 20000 || !encoded || encoded->size() > 960 * 1024) {
    std::move(reply).Run({}, "Invalid native retention snapshot."); return;
  }
  std::vector<history::NativeHistoryRetention> identities;
  std::set<std::pair<std::string, int64_t>> unique;
  for (const auto& group : *groups) {
    const auto* data = group.GetIfDict();
    const auto* generation = data ? data->FindString("generation") : nullptr;
    const auto* visits = data ? data->FindList("visits") : nullptr;
    if (!generation || generation->empty() || generation->size() > 64 || !visits ||
        visits->empty() || visits->size() > 20000 - identities.size()) {
      std::move(reply).Run({}, "Invalid native retention identity group."); return;
    }
    for (const auto& pair : *visits) {
      const auto* values = pair.GetIfList();
      int64_t id = 0, time = 0;
      if (!values || values->size() != 2 || !(*values)[0].is_string() || !(*values)[1].is_string() ||
          !ZacroHistoryDecimal((*values)[0].GetString(), &id) ||
          !ZacroHistoryDecimal((*values)[1].GetString(), &time) || !unique.emplace(*generation, id).second) {
        std::move(reply).Run({}, "Invalid or duplicate retained visit."); return;
      }
      identities.push_back({*generation, id, time});
    }
  }
  const auto request = Queue(std::move(reply));
  service_->ScheduleDBTask(FROM_HERE, std::make_unique<ZacroHistoryRetentionTask>(std::move(identities), base::BindOnce(
      [](base::WeakPtr<ZacroHistoryContext> self, std::string request, bool okay) {
        if (self) self->MutationComplete(request, okay);
      }, weak_.GetWeakPtr(), request)), &tracker_);
}
