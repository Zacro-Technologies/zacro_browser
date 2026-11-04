#include <algorithm>
#include <cassert>
#include <compare>
#include <cstdint>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <optional>
#include <utility>
#include <vector>
#define DCHECK_CURRENTLY_ON(x) static_cast<void>(0)
#define DCHECK(x) assert(x)
#define FROM_HERE 0
namespace base {
template<class T> class WeakPtr {
 public:
  WeakPtr()=default;
  explicit WeakPtr(std::weak_ptr<T> value):value_(std::move(value)){}
  T* get()const{return value_.lock().get();}
  explicit operator bool()const{return get()!=nullptr;}
 private:std::weak_ptr<T> value_;
};
class UnguessableToken {
 public:
  static UnguessableToken Create(){static uint64_t n=0;return UnguessableToken(1,++n);}
  static std::optional<UnguessableToken> Deserialize(uint64_t h,uint64_t l){if(!h&&!l)return std::nullopt;return UnguessableToken(h,l);}
  uint64_t GetHighForSerialization()const{return high_;}
  uint64_t GetLowForSerialization()const{return low_;}
  auto operator<=>(const UnguessableToken&)const=default;
 private:UnguessableToken(uint64_t h,uint64_t l):high_(h),low_(l){}uint64_t high_,low_;
};
template<class Signature> class RepeatingCallback;
template<class R,class... A> class RepeatingCallback<R(A...)> {
 public:RepeatingCallback(std::function<R(A...)> f):f_(std::move(f)){}
  template<class F> RepeatingCallback(F f):f_(std::move(f)){}
  R Run(A...args)const{return f_(std::forward<A>(args)...);}
 private:std::function<R(A...)> f_;
};
using RepeatingClosure=RepeatingCallback<void()>;
template<class T> class NoDestructor {public:T& operator*(){return value_;}private:T value_;};
template<class F,class... A> auto BindOnce(F f,A...args){return [=]{f(args...);};}
class SingleThreadTaskRunner {
 public:static SingleThreadTaskRunner* GetCurrentDefault(){static SingleThreadTaskRunner runner;return &runner;}
  void PostTask(int,std::function<void()> task){tasks.push_back(std::move(task));}
  void Drain(){while(!tasks.empty()){auto task=std::move(tasks.front());tasks.erase(tasks.begin());task();}}
 private:std::vector<std::function<void()>> tasks;
};
}
class Profile:public std::enable_shared_from_this<Profile>{
 public:base::WeakPtr<Profile> GetWeakPtr(){return base::WeakPtr<Profile>(weak_from_this());}
 bool shutdown=false;
 bool ShutdownStarted()const{return shutdown;}
};
