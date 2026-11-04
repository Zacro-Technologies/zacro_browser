int main(){
 using namespace extensions;using Op=NativeWebAuthAdmissionOperation;using R=NativeWebAuthAdmissionResult;
 int checks=0;auto require=[&](bool condition){assert(condition);++checks;};
 auto a=std::make_shared<Profile>(),b=std::make_shared<Profile>();
 int ac=0,bc=0;bool shown=false;
 auto ar=RegisterNativeWebAuthFlow(a.get(),[&]{if(!shown)++ac;},[&]{return shown;});
 auto br=RegisterNativeWebAuthFlow(b.get(),[&]{++bc;},[]{return false;});
 require(ar&&br&&!IsNativeWebAuthAdmissionBlocked(a.get()));
 NativeWebAuthAdmissionState lease;
 require(UpdateNativeWebAuthAdmission(Op::kAcquireContext,a.get(),0,0,&lease)==R::kOk);
 require(ac==1&&bc==0&&IsNativeWebAuthAdmissionBlocked(a.get())&&!IsNativeWebAuthAdmissionBlocked(b.get()));
 require(lease.requests==1&&lease.unpresented==1);
 auto state=lease;ar.reset();
 require(UpdateNativeWebAuthAdmission(Op::kStatus,nullptr,lease.high,lease.low,&state)==R::kOk&&state.requests==1);
 base::SingleThreadTaskRunner::GetCurrentDefault()->Drain();
 require(UpdateNativeWebAuthAdmission(Op::kStatus,nullptr,lease.high,lease.low,&state)==R::kOk&&state.requests==0);
 require(UpdateNativeWebAuthAdmission(Op::kRelease,nullptr,lease.high,lease.low,&state)==R::kOk&&!IsNativeWebAuthAdmissionBlocked(a.get()));
 require(UpdateNativeWebAuthAdmission(Op::kRelease,nullptr,lease.high,lease.low,&state)==R::kUnknownLease);
 shown=true;ar=RegisterNativeWebAuthFlow(a.get(),[&]{if(!shown)++ac;},[&]{return shown;});
 NativeWebAuthAdmissionState global;
 require(UpdateNativeWebAuthAdmission(Op::kAcquireProcess,nullptr,0,0,&global)==R::kOk&&global.requests==2&&global.presented==1&&ac==1&&bc==1);
 auto c=std::make_shared<Profile>();require(IsNativeWebAuthAdmissionBlocked(c.get()));
 auto fenced=RegisterNativeWebAuthFlow(c.get(),[]{},[]{return false;});
 require(fenced&&fenced->is_admitted()&&UpdateNativeWebAuthAdmission(Op::kStatus,nullptr,global.high,global.low,&state)==R::kOk&&state.requests==3);
 fenced.reset();require(UpdateNativeWebAuthAdmission(Op::kStatus,nullptr,global.high,global.low,&state)==R::kOk&&state.requests==3);
 base::SingleThreadTaskRunner::GetCurrentDefault()->Drain();
 require(UpdateNativeWebAuthAdmission(Op::kStatus,nullptr,global.high,global.low,&state)==R::kOk&&state.requests==2);
 auto shutting=std::make_shared<Profile>();shutting->shutdown=true;
 auto rejected=RegisterNativeWebAuthFlow(shutting.get(),[]{},[]{return false;});
 require(rejected&&!rejected->is_admitted()&&UpdateNativeWebAuthAdmission(Op::kStatus,nullptr,global.high,global.low,&state)==R::kOk&&state.requests==3);
 rejected.reset();require(UpdateNativeWebAuthAdmission(Op::kStatus,nullptr,global.high,global.low,&state)==R::kOk&&state.requests==3);
 base::SingleThreadTaskRunner::GetCurrentDefault()->Drain();
 require(UpdateNativeWebAuthAdmission(Op::kStatus,nullptr,global.high,global.low,&state)==R::kOk&&state.requests==2);
 NativeWebAuthAdmissionState nested;
 require(UpdateNativeWebAuthAdmission(Op::kAcquireContext,a.get(),0,0,&nested)==R::kOk);
 require(UpdateNativeWebAuthAdmission(Op::kRelease,nullptr,global.high,global.low,&state)==R::kOk&&IsNativeWebAuthAdmissionBlocked(a.get())&&!IsNativeWebAuthAdmissionBlocked(b.get()));
 require(UpdateNativeWebAuthAdmission(Op::kSeal,nullptr,nested.high,nested.low,&state)==R::kOk&&UpdateNativeWebAuthAdmission(Op::kRelease,nullptr,nested.high,nested.low,&state)==R::kSealed);
 ar.reset();br.reset();base::SingleThreadTaskRunner::GetCurrentDefault()->Drain();a.reset();
 require(UpdateNativeWebAuthAdmission(Op::kStatus,nullptr,nested.high,nested.low,&state)==R::kContextDestroyed);
 auto replacement=std::make_shared<Profile>();require(!IsNativeWebAuthAdmissionBlocked(replacement.get()));
 NativeWebAuthAdmissionState invalid;
 require(UpdateNativeWebAuthAdmission(Op::kAcquireProcess,nullptr,0,0,nullptr)==R::kInvalidArgument);
 invalid.size=0;
 require(UpdateNativeWebAuthAdmission(Op::kAcquireProcess,nullptr,0,0,&invalid)==R::kInvalidArgument);
 invalid=NativeWebAuthAdmissionState();invalid.reserved=1;
 require(UpdateNativeWebAuthAdmission(Op::kAcquireProcess,nullptr,0,0,&invalid)==R::kInvalidArgument);
 invalid=NativeWebAuthAdmissionState();
 require(UpdateNativeWebAuthAdmission(Op::kAcquireContext,nullptr,0,0,&invalid)==R::kInvalidArgument
   &&UpdateNativeWebAuthAdmission(Op::kAcquireProcess,replacement.get(),0,0,&invalid)==R::kInvalidArgument);
 require(UpdateNativeWebAuthAdmission(Op::kAcquireProcess,nullptr,1,1,&invalid)==R::kInvalidArgument);

 // The cancel callback may destroy its exact registration while acquire is
 // iterating. Destruction still remains pending until the posted Forget task.
 std::unique_ptr<NativeWebAuthFlowRegistration> reentrant;
 int reentrant_cancels=0;
 reentrant=RegisterNativeWebAuthFlow(replacement.get(),[&]{++reentrant_cancels;reentrant.reset();},[]{return false;});
 NativeWebAuthAdmissionState reentrant_lease;
 require(UpdateNativeWebAuthAdmission(Op::kAcquireContext,replacement.get(),0,0,&reentrant_lease)==R::kOk
   &&reentrant_cancels==1&&!reentrant&&reentrant_lease.requests==1);
 require(UpdateNativeWebAuthAdmission(static_cast<Op>(99),nullptr,reentrant_lease.high,reentrant_lease.low,&state)==R::kInvalidArgument
   &&IsNativeWebAuthAdmissionBlocked(replacement.get()));
 base::SingleThreadTaskRunner::GetCurrentDefault()->Drain();
 require(UpdateNativeWebAuthAdmission(Op::kStatus,nullptr,reentrant_lease.high,reentrant_lease.low,&state)==R::kOk&&state.requests==0);
 require(UpdateNativeWebAuthAdmission(Op::kRelease,nullptr,reentrant_lease.high,reentrant_lease.low,&state)==R::kOk);

 // Request capacity is explicit. A snapshot counts every registered request;
 // it must never truncate to an empty or smaller apparent quiescent set.
 std::vector<std::unique_ptr<NativeWebAuthFlowRegistration>> capacity_requests;
 for(int i=0;i<8192;++i)capacity_requests.push_back(RegisterNativeWebAuthFlow(replacement.get(),[]{},[]{return false;}));
 require(capacity_requests.back()!=nullptr&&capacity_requests.back()->is_admitted());
 NativeWebAuthAdmissionState capacity_lease;
 require(UpdateNativeWebAuthAdmission(Op::kAcquireContext,replacement.get(),0,0,&capacity_lease)==R::kOk
   &&capacity_lease.requests==8192&&capacity_lease.unpresented==8192);
 auto overflow_request=RegisterNativeWebAuthFlow(replacement.get(),[]{},[]{return false;});
 require(overflow_request&&!overflow_request->is_admitted());
 require(UpdateNativeWebAuthAdmission(Op::kStatus,nullptr,capacity_lease.high,capacity_lease.low,&state)==R::kCapacity);
 NativeWebAuthAdmissionState refused_lease;
 require(UpdateNativeWebAuthAdmission(Op::kAcquireProcess,nullptr,0,0,&refused_lease)==R::kCapacity&&!refused_lease.high&&!refused_lease.low);
 overflow_request.reset();
 require(UpdateNativeWebAuthAdmission(Op::kStatus,nullptr,capacity_lease.high,capacity_lease.low,&state)==R::kCapacity);
 base::SingleThreadTaskRunner::GetCurrentDefault()->Drain();
 require(UpdateNativeWebAuthAdmission(Op::kStatus,nullptr,capacity_lease.high,capacity_lease.low,&state)==R::kOk&&state.requests==8192);
 capacity_requests.clear();
 require(UpdateNativeWebAuthAdmission(Op::kStatus,nullptr,capacity_lease.high,capacity_lease.low,&state)==R::kOk&&state.requests==8192);
 base::SingleThreadTaskRunner::GetCurrentDefault()->Drain();
 require(UpdateNativeWebAuthAdmission(Op::kStatus,nullptr,capacity_lease.high,capacity_lease.low,&state)==R::kOk&&state.requests==0);
 require(UpdateNativeWebAuthAdmission(Op::kRelease,nullptr,capacity_lease.high,capacity_lease.low,&state)==R::kOk);

 std::vector<NativeWebAuthAdmissionState> capacity_leases;
 for(int i=0;i<128;++i){NativeWebAuthAdmissionState next;require(UpdateNativeWebAuthAdmission(Op::kAcquireProcess,nullptr,0,0,&next)==R::kOk);capacity_leases.push_back(next);}
 NativeWebAuthAdmissionState overflow;
 require(UpdateNativeWebAuthAdmission(Op::kAcquireProcess,nullptr,0,0,&overflow)==R::kCapacity);
 for(const auto& next:capacity_leases)require(UpdateNativeWebAuthAdmission(Op::kRelease,nullptr,next.high,next.low,&state)==R::kOk);
 require(!IsNativeWebAuthAdmissionBlocked(replacement.get()));
 std::cout<<"{\"checks\":"<<checks<<"}\n";
}
