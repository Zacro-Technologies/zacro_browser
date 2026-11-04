#include <algorithm>
#include <cassert>
#include <cmath>
#include <iostream>
#include <map>
#include <optional>

namespace gfx {
struct Size {
  int w = 0, h = 0;
  int width() const { return w; }
  int height() const { return h; }
};
struct Rect {
  int xx = 0, yy = 0, w = 0, h = 0;
  Rect() = default;
  Rect(int x, int y, int width, int height) : xx(x), yy(y), w(width), h(height) {}
  int x() const { return xx; }
  int y() const { return yy; }
  int width() const { return w; }
  int height() const { return h; }
  int right() const { return xx + w; }
  int bottom() const { return yy + h; }
  bool IsEmpty() const { return w <= 0 || h <= 0; }
  void Offset(int dx, int dy) { xx += dx; yy += dy; }
  void Intersect(const Rect& other) {
    const int left = std::max(xx, other.xx), top = std::max(yy, other.yy);
    const int edge = std::min(right(), other.right()), end = std::min(bottom(), other.bottom());
    *this = edge > left && end > top ? Rect(left, top, edge - left, end - top) : Rect();
  }
  bool operator==(const Rect&) const = default;
};
}
namespace base {
int ClampFloor(double value) { return static_cast<int>(std::floor(value)); }
namespace i18n { bool rtl = false; bool IsRTL() { return rtl; } }
}
struct Layer { double opacity = 0; void SetOpacity(double value) { opacity = value; } };
struct View {
  View* parent = nullptr;
  bool visible = true;
  gfx::Rect frame;
  Layer paint_layer;
  Layer* layer() { return &paint_layer; }
  int x() const { return frame.x(); }
  int y() const { return frame.y(); }
  int width() const { return frame.width(); }
  int height() const { return frame.height(); }
  gfx::Rect bounds() const { return frame; }
  gfx::Rect GetLocalBounds() const { return gfx::Rect(0, 0, width(), height()); }
};
struct Transition : View {
  double translation = 0;
  gfx::Rect clip;
  void UpdateHorizontalTranslation(double value) { translation = value; }
  void ClipBounds(gfx::Rect value) { clip = value; }
};
struct SidePanel : View {
  int minimum = 320, preferred = 400;
  bool right_aligned = true;
  double reveal = 1;
  int animation_calls = 0;
  std::optional<gfx::Rect> clip;
  gfx::Size GetMinimumSize() const { return {minimum, 0}; }
  gfx::Size GetPreferredSize() const { return {preferred, 1}; }
  double GetAnimationValue() const { return reveal; }
  bool IsRightAligned() const { return right_aligned; }
  gfx::Rect GetContentAnimationBounds(const gfx::Rect& final) { ++animation_calls; return final; }
  void SetClipToVisibleArea(std::optional<gfx::Rect> value) { clip = value; }
};
template <class T> struct Pointer {
  T* value = nullptr;
  Pointer(T* pointer = nullptr) : value(pointer) {}
  T* get() const { return value; }
  T* operator->() const { return value; }
  operator T*() const { return value; }
};
namespace SidePanelAnimations {
constexpr int kSidePanel = 0, kContentScrimOpacity = 1, kContentTransitionOffset = 2, kPanelWidth = 3;
}
struct AnimationController {
  std::map<int, double> values;
  std::optional<double> GetCurrentValue(int, int sequence) const {
    auto found = values.find(sequence);
    return found == values.end() ? std::nullopt : std::make_optional(found->second);
  }
};
struct Delegate {
  mutable AnimationController controller;
  AnimationController* GetAnimationController() const { return &controller; }
};
struct BrowserLayoutParams {
  gfx::Rect visual_client_area;
  void InsetHorizontal(int width, bool leading) {
    visual_client_area.w -= width;
    if (leading) visual_client_area.xx += width;
  }
};
struct BrowserViewPopupLayoutImpl {
  struct ProposedLayout {
    std::map<View*, gfx::Rect> children;
    void AddChild(View* view, gfx::Rect bounds, bool visible = true) {
      children[view] = bounds;
      view->visible = visible;
    }
  };
  struct Views {
    Pointer<SidePanel> side_panel;
    View* browser_view;
    Pointer<Transition> side_panel_animation_content;
    Pointer<View> side_panel_content_transition_scrim;
    Pointer<View> multi_contents_view;
  } state;
  static constexpr int kContentsContainerMinimumWidth = 200;
  bool native_side_panel_ = false;
  Delegate layout_delegate;
  const Views& views() const { return state; }
  const Delegate& delegate() const { return layout_delegate; }
  static bool IsParentedTo(View* child, View* parent) {
    return child && child->parent == parent;
  }
  static bool IsParentedToAndVisible(View* child, View* parent) {
    return child && child->parent == parent && child->visible;
  }
  void LayoutNativeSidePanel(ProposedLayout& layout, BrowserLayoutParams& params) const;
  void DoPostLayoutVisualAdjustments(const BrowserLayoutParams& params);
};

// ACTUAL_GENERATED_METHODS

int main() {
  int checks = 0;
  auto require = [&](bool condition) { assert(condition); ++checks; };
  View host, foreign, contents, scrim;
  Transition transition;
  SidePanel panel;
  panel.parent = &host;
  BrowserViewPopupLayoutImpl subject{{&panel, &host, nullptr, nullptr, &contents}, false, {}};
  const gfx::Rect viewport(10, 20, 1208, 932);
  auto run = [&] {
    BrowserLayoutParams params{viewport};
    BrowserViewPopupLayoutImpl::ProposedLayout layout;
    subject.LayoutNativeSidePanel(layout, params);
    return std::make_pair(params, layout);
  };
  auto [ordinary, none] = run();
  require(none.children.empty() && ordinary.visual_client_area == viewport);
  subject.native_side_panel_ = true;
  auto [right, full] = run();
  require(full.children.at(&panel) == gfx::Rect(818, 20, 400, 932));
  require(right.visual_client_area == gfx::Rect(10, 20, 808, 932));
  panel.reveal = .5;
  auto [partial, half] = run();
  require(half.children.at(&panel) == gfx::Rect(1018, 20, 400, 932));
  require(partial.visual_client_area == gfx::Rect(10, 20, 1008, 932));
  panel.frame = half.children.at(&panel);
  subject.DoPostLayoutVisualAdjustments({viewport});
  require(panel.clip == gfx::Rect(0, 0, 200, 932));
  panel.right_aligned = false;
  auto [left, left_half] = run();
  require(left_half.children.at(&panel) == gfx::Rect(-190, 20, 400, 932));
  require(left.visual_client_area == gfx::Rect(210, 20, 1008, 932));
  panel.frame = left_half.children.at(&panel);
  subject.DoPostLayoutVisualAdjustments({viewport});
  require(panel.clip == gfx::Rect(200, 0, 200, 932));
  base::i18n::rtl = true;
  auto [rtl, rtl_right] = run();
  require(rtl.visual_client_area == partial.visual_client_area &&
          rtl_right.children.at(&panel) == half.children.at(&panel));
  base::i18n::rtl = false;
  panel.reveal = 0;
  auto [closed, at_zero] = run();
  require(closed.visual_client_area == viewport);
  panel.frame = at_zero.children.at(&panel);
  subject.DoPostLayoutVisualAdjustments({viewport});
  require(panel.clip && !panel.clip->IsEmpty() && panel.clip->x() >= panel.width());
  panel.reveal = 1;
  auto [opened, at_one] = run();
  panel.frame = at_one.children.at(&panel);
  subject.DoPostLayoutVisualAdjustments({viewport});
  require(!panel.clip);
  panel.preferred = 5000;
  auto [resized, large] = run();
  require(resized.visual_client_area.width() == 200 && large.children.at(&panel).width() == 1008);
  panel.preferred = 1;
  auto [minimum, small] = run();
  require(small.children.at(&panel).width() == panel.minimum);
  transition.parent = &host;
  subject.state.side_panel_animation_content = &transition;
  auto [moving, animated] = run();
  require(animated.children.contains(&transition) && panel.animation_calls == 1 &&
          animated.children.at(&transition) == animated.children.at(&panel));
  transition.frame = gfx::Rect(10, 20, 500, 932);
  contents.frame = gfx::Rect(330, 20, 888, 932);
  subject.layout_delegate.controller.values[SidePanelAnimations::kContentTransitionOffset] = -50;
  subject.layout_delegate.controller.values[SidePanelAnimations::kPanelWidth] = 0;
  subject.DoPostLayoutVisualAdjustments({viewport});
  require(transition.translation == -50 && transition.clip == gfx::Rect(370, 0, 130, 932));
  subject.layout_delegate.controller.values[SidePanelAnimations::kPanelWidth] = .5;
  subject.DoPostLayoutVisualAdjustments({viewport});
  require(transition.clip == gfx::Rect(50, 0, 450, 932));
  scrim.parent = &host;
  subject.state.side_panel_content_transition_scrim = &scrim;
  subject.layout_delegate.controller.values[SidePanelAnimations::kContentScrimOpacity] = .4;
  auto [scrim_area, with_scrim] = run();
  subject.DoPostLayoutVisualAdjustments({viewport});
  require(with_scrim.children.at(&scrim) == viewport && scrim.visible && scrim.paint_layer.opacity == .4);
  subject.layout_delegate.controller.values[SidePanelAnimations::kContentScrimOpacity] = 0;
  run();
  subject.DoPostLayoutVisualAdjustments({viewport});
  require(!scrim.visible && scrim.paint_layer.opacity == 0);
  panel.visible = false;
  auto [hidden, no_hidden] = run();
  require(no_hidden.children.empty() && hidden.visual_client_area == viewport);
  panel.visible = true; panel.parent = &foreign;
  auto [unowned, no_foreign] = run();
  require(no_foreign.children.empty() && unowned.visual_client_area == viewport);
  panel.parent = &host;
  BrowserLayoutParams tiny{gfx::Rect(0, 0, 1, 15)};
  BrowserViewPopupLayoutImpl::ProposedLayout tiny_layout;
  subject.LayoutNativeSidePanel(tiny_layout, tiny);
  require(tiny.visual_client_area.width() == 1 && tiny_layout.children.at(&panel).width() == 0);
  BrowserLayoutParams split{gfx::Rect(0, 0, 160, 932)};
  BrowserViewPopupLayoutImpl::ProposedLayout split_layout;
  subject.LayoutNativeSidePanel(split_layout, split);
  require(split.visual_client_area.width() == 1 && split_layout.children.at(&panel).width() == 159 &&
          split.visual_client_area.x() == split_layout.children.at(&panel).right());
  subject.state.side_panel.value = nullptr;
  auto [missing, no_panel] = run();
  require(no_panel.children.empty() && missing.visual_client_area == viewport);
  std::cout << "{\"checks\":" << checks << "}\n";
}
