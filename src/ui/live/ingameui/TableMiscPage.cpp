// license:GPLv3+

#include "core/stdafx.h"
#include "TableMiscPage.h"

#include "core/VPApp.h"
#include "renderer/Renderer.h"
#include "ui/live/LiveUI.h"


namespace VPX::InGameUI
{

TableMiscPage::TableMiscPage()
   : InGameUIPage("General Table Settings"s, ""s, SaveMode::Both)
{
}

void TableMiscPage::Open(bool isBackwardAnimation)
{
   InGameUIPage::Open(isBackwardAnimation);
   m_staticPrepassDisabled = false;
}

void TableMiscPage::Close(bool isBackwardAnimation)
{
   InGameUIPage::Close(isBackwardAnimation);
   if (m_staticPrepassDisabled)
      m_player->m_renderer->DisableStaticPrePass(false);
}

void TableMiscPage::RequestDynamicRendererUpdate()
{
   if (!m_staticPrepassDisabled)
   {
      m_player->m_renderer->DisableStaticPrePass(true);
      m_staticPrepassDisabled = true;
   }
   m_player->m_renderer->MarkShaderDirty();
   m_player->m_ptable->FireOptionEvent(PinTable::OptionEventType::Changed);
}

void TableMiscPage::BuildPage()
{
   // Look: a mix of the settings below to start from, stepped through live; changing one of them by hand makes it 'Custom'
   AddItem(std::make_unique<InGameUIItem>( //
      Settings::m_propTableOverride_Look, //
      [this]() { return m_player->m_renderer->m_look; }, //
      [this](int, int v)
      {
         m_player->m_renderer->ApplyLook(v);
         RequestDynamicRendererUpdate();
         RequestRebuild();
      }));
   auto custom = [this]() { m_player->m_renderer->m_look = Renderer::LOOK_CUSTOM; };

   // Tonemapper, as a table override, if not using WCG display tonemapper
   if (!m_player->m_renderer->m_HDRforceDisableToneMapper || !m_player->m_playfieldWnd->IsWCGBackBuffer())
   {
      Settings::SetTableOverride_ToneMapper_Default(m_player->m_ptable->GetToneMapper());
      AddItem(std::make_unique<InGameUIItem>( //
         Settings::m_propTableOverride_ToneMapper, //
         [this]() { return static_cast<int>(m_player->m_renderer->m_toneMapper); }, //
         [this, custom](int, int v)
         {
            m_player->m_renderer->m_toneMapper = static_cast<ToneMapper>(v);
            custom();
         }));
   }

   // Exposure, always saved as a table override setting if different from table embedded value
   // FIXME this conflicts with HDR adjusting exposure
   Settings::SetTableOverride_Exposure_Default(m_player->m_ptable->GetExposure());
   AddItem(std::make_unique<InGameUIItem>( //
      Settings::m_propTableOverride_Exposure, 100.f, "%4.1f %%"s, //
      [this]() { return m_player->m_renderer->m_exposure; }, //
      [this, custom](float, float v)
      {
         m_player->m_renderer->m_exposure = v;
         custom();
         m_player->m_ptable->FireOptionEvent(PinTable::OptionEventType::Changed);
      }));

   // Color boost after tonemapping
   AddItem(std::make_unique<InGameUIItem>( //
      Settings::m_propTableOverride_Saturation, 100.f, "%4.0f %%"s, //
      [this]() { return m_player->m_renderer->m_saturation; }, //
      [this, custom](float, float v)
      {
         m_player->m_renderer->m_saturation = v;
         custom();
      }));
   AddItem(std::make_unique<InGameUIItem>( //
      Settings::m_propTableOverride_Contrast, 100.f, "%4.0f %%"s, //
      [this]() { return m_player->m_renderer->m_contrast; }, //
      [this, custom](float, float v)
      {
         m_player->m_renderer->m_contrast = v;
         custom();
      }));

   // Global emission scale, if not overriden on commandline
   #ifndef ENABLE_BGFX
   if (!g_app->m_bgles)
   #endif
   {
      AddItem(std::make_unique<InGameUIItem>(
         VPX::Properties::EnumPropertyDef(
            ""s, ""s, "Scene Lighting"s, "Select how scene lighting is evaluated"s, false, 0, 0, vector { "Table's default"s, "Custom fixed value"s, "Time of day"s }),
         [this]() { return (int) m_player->m_renderer->m_sceneLighting.GetMode(); }, // Live
         [this](const Settings& settings)
         { 
            if (!settings.GetPlayer_OverrideTableEmissionScale())
               return 0;
            if (!settings.GetPlayer_DynamicDayNight())
               return 1;
            return 2;
         }, // Stored
         [this, custom](int, int v)
         {
            m_player->m_renderer->m_sceneLighting.SetMode((Renderer::SceneLighting::Mode)v);
            custom();
            RequestDynamicRendererUpdate();
            RequestRebuild();
         },
         [](Settings& settings)
         {
            settings.ResetPlayer_OverrideTableEmissionScale();
            settings.ResetPlayer_DynamicDayNight();
         },
         [](int v, Settings& settings, bool isTableOverride)
         {
            settings.SetPlayer_OverrideTableEmissionScale(v != 0, isTableOverride);
            settings.SetPlayer_DynamicDayNight(v == 2, isTableOverride);
         }));

      if (m_player->m_renderer->m_sceneLighting.GetMode() == Renderer::SceneLighting::Mode::User)
      {
         Settings::SetPlayer_EmissionScale_Default(m_player->m_ptable->m_globalEmissionScale);
         AddItem(std::make_unique<InGameUIItem>(
            Settings::m_propPlayer_EmissionScale, 100.f, "%4.1f %%"s,  //
            [this]() { return m_player->m_renderer->m_sceneLighting.GetUserLightLevel(); },
            [this, custom](float, float v)
            {
               m_player->m_renderer->m_sceneLighting.SetUserLightLevel(v);
               custom();
               RequestDynamicRendererUpdate();
            }));
      }
      else if (m_player->m_renderer->m_sceneLighting.GetMode() == Renderer::SceneLighting::Mode::DayNight)
      {
         AddItem(std::make_unique<InGameUIItem>( //
            Settings::m_propPlayer_Latitude, 1.f, "%4.1f deg"s, //
            [this]() { return m_player->m_renderer->m_sceneLighting.GetLatitude(); }, //
            [this](float, float v) {
               m_player->m_renderer->m_sceneLighting.SetLatitude(v);
               RequestDynamicRendererUpdate();
            }));
         AddItem(std::make_unique<InGameUIItem>( //
            Settings::m_propPlayer_Longitude, 1.f, "%4.1f deg"s, //
            [this]() { return m_player->m_renderer->m_sceneLighting.GetLongitude(); }, //
            [this](float, float v) {
               m_player->m_renderer->m_sceneLighting.SetLongitude(v);
               RequestDynamicRendererUpdate();
            }));
      }

      // Difficulty, always saved as a table override setting if different from table embedded value
      Settings::SetTableOverride_Difficulty_Default(m_player->m_ptable->m_difficulty);
      AddItem(std::make_unique<InGameUIItem>( //
         Settings::m_propTableOverride_Difficulty, 100.f, "%4.1f %%"s, //
         [this]() { return m_player->m_ptable->m_globalDifficulty; }, //
         [this](float, float v)
         {
            m_player->m_ptable->m_globalDifficulty = v;
            m_player->m_ptable->FireOptionEvent(PinTable::OptionEventType::Changed);
            m_difficultyNotification
               = m_player->m_liveUI->PushNotification("You have changed the difficulty level\nThis change will only be applied after restart."s, 5000, m_difficultyNotification);
         }));
   }
}

}
