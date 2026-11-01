// license:GPLv3+

#pragma once

#include "core/def.h"
#include "input/InputManager.h"
#include "renderer/Renderer.h"

#include "imgui/imgui.h"
#include "imgui_markdown/imgui_markdown.h"

#include "PerfUI.h"
#include "ingameui/InGameUI.h"
#include "EditorUI.h"
#include "NotificationOverlay.h"
#include "PlumbOverlay.h"
#include "BallControl.h"
#include "DebuggerUI.h"

class LiveUI final : public UserMessageSink
{
public:
   LiveUI(RenderDevice* const rd);
   ~LiveUI();

   // UserMessageSink interface: non fatal messages are routed to the in-game notification
   // overlay, while fatal errors and confirmations use a (blocking) SDL message box.
   void Notify(MsgSeverity severity, const string &title, const string &message) override;
   bool Confirm(const string &title, const string &message, bool fallback) override;

   void Render3D(); // Called to contribute to 3D Scene
   void RenderUI(); // Called to render UI overlay

   bool IsOpened() const { return IsEditorUIOpened() || IsInGameUIOpened(); }
   void HideUI();

   void OpenEditorUI() { m_editorUI.Open(); }
   bool IsEditorUIOpened() const { return m_editorUI.IsOpened(); }
   bool IsEditorViewMode() const { return m_editorUI.IsOpened() && !m_editorUI.IsPreview(); }
   bool IsEditorBackdropViewMode() const { return m_editorUI.IsOpened() && m_editorUI.IsBackdropEditMode(); }

   void OpenInGameUI(const string& page = "homepage"s);
   bool IsInGameUIOpened() const { return m_inGameUI.IsOpened(); }

   void ToggleFPS() { m_perfUI.NextPerfMode(); }
   bool IsShowingFPSDetails() const { return m_perfUI.GetPerfMode() != PerfUI::PerfMode::PM_DISABLED; }
   
   void ShowTouchOverlay(bool show) { m_showTouchOverlay = show; }
   // Shows the touch regions, labelled, for a while (when a table starts, for players new to them)
   void ShowTouchHint(uint32_t lengthMs);

   // A finger on the playfield (phase: InputManager::TouchPhase), true when the embedded score display takes
   // it: held for half a second, the display goes into edit mode (game paused), to be dragged, pinched and
   // faded, a tap outside of it ending the edit
   bool OnTouch(uint64_t finger, float x, float y, int phase);

   unsigned int PushNotification(const string &message, const int lengthMs, const unsigned int reuseId = 0) { return m_notificationOverlay.PushNotification(message, lengthMs, reuseId); }

   // Ball Control
   BallControl m_ballControl;

   // Debugger (play/pause/step, ball control, script console)
   DebuggerUI m_debuggerUI;
   bool IsDebuggerOpened() const { return m_debuggerUI.IsOpened(); }

   // Editor UI
   VPX::EditorUI::EditorUI m_editorUI;

   // In Game UI
   VPX::InGameUI::InGameUI m_inGameUI;

   // Profiler display data
   PerfUI m_perfUI;

   // UI context (to be moved outside of LiveUI API)
   void SetMarkdownStartId(const unsigned int startId) { markdown_start_id = startId; }
   const ImGui::MarkdownConfig &GetMarkdownConfig() const { return markdown_config; }
   ImFont *GetOverlayFont() const { return m_overlayFont; }
   float GetDPI() const { return m_uiScale; }
   int GetUIOrientation() const { return m_rotate; }
   static ImGuiKey GetImGuiKeyFromSDLScancode(const SDL_Scancode sdlk);
   static void CenteredText(const string &text);

   void HandleSDLEvent(SDL_Event &e) const;

private:
   void SetupImGuiStyle(const bool isEditor) const;
   
   void NewFrame();
   void AddMousePosEvent(bool isTouch, float x, float y) const;
   void UpdateScale();
   void UpdatePlayfieldWindowFrame();
   bool m_playfieldWindowFramed = false;

   vector<std::shared_ptr<MeshBuffer>> m_meshBuffers;

   // Touch UI overlay
   void UpdateTouchUI();
   bool m_showTouchOverlay;

   // The score display's edit mode (see OnTouch), positions relative to the playfield window
   enum class ScoreViewEdit { None, Holding, Editing };
   static constexpr uint64_t NoFinger = ~0ull;
   bool IsScoreViewEditable() const;
   vec4 GetScoreViewHitArea() const; // the display, or the tab left of it once hidden
   vec4 GetScoreViewSlider() const;
   void UpdateScoreViewEditor();
   void EndScoreViewEdit();
   ScoreViewEdit m_scoreViewEdit = ScoreViewEdit::None;
   uint64_t m_holdFinger = NoFinger;
   uint32_t m_holdStart = 0;
   ImVec2 m_holdPos;
   uint64_t m_dragFinger = NoFinger;
   uint64_t m_pinchFinger = NoFinger;
   uint64_t m_sliderFinger = NoFinger;
   ImVec2 m_dragPos, m_dragStart, m_pinchPos;
   float m_pinchStartDistance = 0.f;
   vec4 m_editStartSpot;
   uint32_t m_touchHintUntil = 0;

   // Emulated plumb overlay
   PlumbOverlay m_plumbOverlay;

   // Notifications
   NotificationOverlay m_notificationOverlay;

   // MarkDown support
   ImGuiID markdown_start_id;
   static ImGui::MarkdownConfig markdown_config;
   static void MarkdownFormatCallback(const ImGui::MarkdownFormatInfo &markdownFormatInfo, bool start);
   static void MarkdownLinkCallback(ImGui::MarkdownLinkCallbackData data);
   static ImGui::MarkdownImageData MarkdownImageCallback(ImGui::MarkdownLinkCallbackData data);

   // UI Context
   Player   *m_player;
   InputManager *m_pininput;
   std::unique_ptr<Renderer>& m_renderer;

   // Rendering
   RenderDevice* const m_rd;
   int m_rotate = 0;
   float m_uiScale = 0.f;
   ImFont *m_baseFont = nullptr;
   ImFont *m_overlayBoldFont = nullptr;
   ImFont *m_overlayFont = nullptr;
};

namespace plog
{
Record &operator<<(Record &record, const ImVec2 &pt);
}
