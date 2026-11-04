// Included in web_auth_flow.cc, within namespace extensions. The registration
// member is declared before the flow's owned WebContents, so its destructor
// runs after those contents and all later members have actually been destroyed.
namespace {
struct NativeAuthLease {
  bool process = false;
  bool sealed = false;
  base::WeakPtr<Profile> profile;
};
struct NativeAuthRequest {
  base::WeakPtr<Profile> profile;
  base::RepeatingClosure cancel_unpresented;
  base::RepeatingCallback<bool()> is_presented;
};
struct NativeAuthRegistry {
  std::map<base::UnguessableToken, NativeAuthLease> leases;
  std::map<base::UnguessableToken, NativeAuthRequest> requests;
  // Capacity-refused flows still have an original asynchronous failure and
  // destructor. A counter keeps their lifetime visible without growing the
  // bounded request map or presenting a truncated quiescent snapshot.
  uint64_t overflow_requests = 0;
};
NativeAuthRegistry& NativeAuthState() {
  static base::NoDestructor<NativeAuthRegistry> state;
  return *state;
}
bool NativeAuthMatches(const NativeAuthLease& lease, const NativeAuthRequest& request) {
  return lease.process || (lease.profile && request.profile.get() == lease.profile.get());
}
void ForgetNativeAuthRequest(const base::UnguessableToken& id) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  NativeAuthState().requests.erase(id);
}
void ForgetNativeAuthOverflow() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  DCHECK(NativeAuthState().overflow_requests);
  --NativeAuthState().overflow_requests;
}
}  // namespace

NativeWebAuthFlowRegistration::NativeWebAuthFlowRegistration(base::UnguessableToken id,
                                                           bool admitted, bool overflow)
    : id_(id), admitted_(admitted), overflow_(overflow) {}
NativeWebAuthFlowRegistration::~NativeWebAuthFlowRegistration() {
  // A status query must not observe quiescence reentrantly inside the enclosing
  // destructor/notification stack. Keep the identity until the next UI task.
  if (overflow_) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&ForgetNativeAuthOverflow));
  } else {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&ForgetNativeAuthRequest, id_));
  }
}
std::unique_ptr<NativeWebAuthFlowRegistration> RegisterNativeWebAuthFlow(
    Profile* profile, base::RepeatingClosure cancel_unpresented,
    base::RepeatingCallback<bool()> is_presented) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto& state = NativeAuthState();
  if (!profile) return nullptr;
  const auto id = base::UnguessableToken::Create();
  if (state.requests.size() >= 8192) {
    ++state.overflow_requests;
    return std::make_unique<NativeWebAuthFlowRegistration>(id, false, true);
  }
  state.requests.emplace(id, NativeAuthRequest{profile->GetWeakPtr(),
      std::move(cancel_unpresented), std::move(is_presented)});
  return std::make_unique<NativeWebAuthFlowRegistration>(id, !profile->ShutdownStarted());
}
bool IsNativeWebAuthAdmissionBlocked(Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!profile || profile->ShutdownStarted()) return true;
  for (const auto& [id, lease] : NativeAuthState().leases) {
    if (lease.process || lease.profile.get() == profile) return true;
  }
  return false;
}
NativeWebAuthAdmissionResult UpdateNativeWebAuthAdmission(
    NativeWebAuthAdmissionOperation operation, Profile* profile,
    uint64_t high, uint64_t low, NativeWebAuthAdmissionState* output) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  using Result = NativeWebAuthAdmissionResult;
  using Operation = NativeWebAuthAdmissionOperation;
  if (!output || output->size != sizeof(*output) || output->reserved) return Result::kInvalidArgument;
  *output = NativeWebAuthAdmissionState();
  if (operation == Operation::kIsBlocked) {
    if (!profile) return Result::kInvalidArgument;
    output->requests = IsNativeWebAuthAdmissionBlocked(profile) ? 1 : 0;
    return Result::kOk;
  }
  auto& state = NativeAuthState();
  std::optional<base::UnguessableToken> token;
  const bool acquire = operation == Operation::kAcquireContext || operation == Operation::kAcquireProcess;
  // Refused flow objects can still have pending failure/destruction callbacks.
  // Do not allocate an unreturned lease or report zero while they drain.
  // Explicit release remains possible, including cancellation of an old Quit.
  if (state.overflow_requests &&
      (acquire || operation == Operation::kStatus || operation == Operation::kSeal)) return Result::kCapacity;
  if (acquire) {
    if (high || low || (operation == Operation::kAcquireContext && (!profile || profile->ShutdownStarted())) ||
        (operation == Operation::kAcquireProcess && profile)) return Result::kInvalidArgument;
    // Expired profile leases cannot transfer authority to a recycled address.
    std::erase_if(state.leases, [](const auto& entry) {
      return !entry.second.process && !entry.second.profile;
    });
    if (state.leases.size() >= 128) return Result::kCapacity;
    token = base::UnguessableToken::Create();
    state.leases.emplace(*token, NativeAuthLease{operation == Operation::kAcquireProcess,
        false, profile ? profile->GetWeakPtr() : base::WeakPtr<Profile>()});
  } else {
    token = base::UnguessableToken::Deserialize(high, low);
    if (!token) return Result::kInvalidArgument;
  }
  auto it = state.leases.find(*token);
  if (it == state.leases.end()) return Result::kUnknownLease;
  // Copy before any delegate callback, which may mutate the registry.
  const auto lease = it->second;
  if (!lease.process && !lease.profile) return Result::kContextDestroyed;
  if (operation == Operation::kRelease) {
    if (lease.sealed) return Result::kSealed;
    state.leases.erase(it);
    return Result::kOk;
  }
  if (operation == Operation::kSeal) it->second.sealed = true;
  else if (!acquire && operation != Operation::kStatus) return Result::kInvalidArgument;
  if (acquire) {
    std::vector<base::UnguessableToken> ids;
    for (const auto& [id, request] : state.requests) if (NativeAuthMatches(lease, request)) ids.push_back(id);
    // Admission is already closed. A failure callback may reenter, remove a
    // request, or destroy the Profile. Never retain a raw request across it.
    for (const auto& id : ids) {
      auto request = state.requests.find(id);
      if (request == state.requests.end()) continue;
      auto cancel = request->second.cancel_unpresented;
      cancel.Run();
    }
  }
  output->high = token->GetHighForSerialization();
  output->low = token->GetLowForSerialization();
  // Count a fresh registry. Entries whose flow WeakPtr has expired remain
  // pending until the destructor's posted Forget task; false is unpresented.
  for (const auto& [id, request] : state.requests) {
    if (!NativeAuthMatches(lease, request)) continue;
    ++output->requests;
    if (request.is_presented.Run()) ++output->presented;
    else ++output->unpresented;
  }
  return Result::kOk;
}
