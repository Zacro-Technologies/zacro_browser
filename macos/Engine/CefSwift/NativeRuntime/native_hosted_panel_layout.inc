void BrowserViewPopupLayoutImpl::LayoutNativeSidePanel(
    ProposedLayout& layout, BrowserLayoutParams& params) const {
  auto* panel = views().side_panel.get();
  if (!native_side_panel_ ||
      !IsParentedToAndVisible(panel, views().browser_view)) {
    return;
  }
  // Keep the actual SidePanel's preference/resize state. Native shell layout
  // can briefly be smaller than minimum size; never produce overlapping or
  // negative document bounds during those resize passes.
  const int minimum_panel = panel->GetMinimumSize().width();
  const int minimum_document = std::min(kContentsContainerMinimumWidth,
      std::max(1, params.visual_client_area.width() - minimum_panel));
  const int available = std::max(0,
      params.visual_client_area.width() - minimum_document);
  const int preferred = std::max(minimum_panel,
                                 panel->GetPreferredSize().width());
  const int target_width = std::min(preferred, available);
  const int visible_width = base::ClampFloor(
      target_width * std::clamp(panel->GetAnimationValue(), 0.0, 1.0));
  const bool leading = panel->IsRightAligned() == base::i18n::IsRTL();
  const gfx::Rect area = params.visual_client_area;
  const gfx::Rect panel_bounds(
      leading ? area.x() - (target_width - visible_width)
              : area.right() - visible_width,
      area.y(), target_width, area.height());
  layout.AddChild(panel, panel_bounds);

  // Chromium reparents the same live extension view here for a content
  // transition. Preserve its actual animation, rather than recreating it.
  if (IsParentedToAndVisible(views().side_panel_animation_content,
                            views().browser_view)) {
    const gfx::Rect final_bounds(
        leading ? area.x() : area.right() - target_width,
        area.y(), target_width, area.height());
    layout.AddChild(views().side_panel_animation_content,
                    panel->GetContentAnimationBounds(final_bounds));
  }
  if (IsParentedTo(views().side_panel_content_transition_scrim,
                    views().browser_view)) {
    const double opacity = delegate().GetAnimationController()->GetCurrentValue(
        SidePanelAnimations::kSidePanel,
        SidePanelAnimations::kContentScrimOpacity).value_or(0.0);
    layout.AddChild(views().side_panel_content_transition_scrim, area,
                    opacity > 0.0);
  }
  params.InsetHorizontal(visible_width, leading);
}

void BrowserViewPopupLayoutImpl::DoPostLayoutVisualAdjustments(
    const BrowserLayoutParams& params) {
  auto* panel = views().side_panel.get();
  if (!native_side_panel_ ||
      !IsParentedToAndVisible(panel, views().browser_view)) {
    return;
  }
  auto* controller = delegate().GetAnimationController();
  if (auto* scrim = views().side_panel_content_transition_scrim.get();
      IsParentedTo(scrim, views().browser_view) && scrim->layer()) {
    scrim->layer()->SetOpacity(controller->GetCurrentValue(
        SidePanelAnimations::kSidePanel,
        SidePanelAnimations::kContentScrimOpacity).value_or(0.0));
  }
  auto* transition = views().side_panel_animation_content.get();
  if (IsParentedToAndVisible(transition, views().browser_view)) {
    double translation = controller->GetCurrentValue(
        SidePanelAnimations::kSidePanel,
        SidePanelAnimations::kContentTransitionOffset).value_or(0.0);
    if (panel->IsRightAligned() != base::i18n::IsRTL()) translation = -translation;
    transition->UpdateHorizontalTranslation(translation);
    const auto panel_width = controller->GetCurrentValue(
        SidePanelAnimations::kSidePanel, SidePanelAnimations::kPanelWidth);
    const bool first_part = !panel_width || *panel_width == 0.0;
    const gfx::Rect allowed = first_part ? views().multi_contents_view->bounds()
                                        : params.visual_client_area;
    gfx::Rect transformed = transition->bounds();
    transformed.Offset(static_cast<int>(translation), 0);
    gfx::Rect clipped = transformed;
    clipped.Intersect(allowed);
    if (clipped == transformed) {
      transition->ClipBounds(gfx::Rect());
    } else {
      clipped.Offset(-transformed.x(), -transformed.y());
      if (clipped.IsEmpty()) clipped = gfx::Rect(-1, 0, 1, std::max(1, transition->height()));
      transition->ClipBounds(clipped);
    }
  }
  // SidePanel's native WebContents must share the Views clip while revealing
  // outside the client area; otherwise its Cocoa renderer can overlap chrome.
  gfx::Rect visible = panel->bounds();
  visible.Intersect(params.visual_client_area);
  visible.Offset(-panel->x(), -panel->y());
  if (visible == panel->GetLocalBounds()) {
    panel->SetClipToVisibleArea(std::nullopt);
  } else {
    // NativeViewHost uses an empty clip to mean no clip. At animation zero,
    // keep a one-pixel clip just OUTSIDE the panel's local content instead.
    if (visible.IsEmpty()) {
      visible = gfx::Rect(panel->IsRightAligned() == base::i18n::IsRTL()
                             ? panel->width() : -1,
                         0, 1, std::max(1, panel->height()));
    }
    panel->SetClipToVisibleArea(visible);
  }
}
