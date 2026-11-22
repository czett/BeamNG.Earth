// BeamNG.Earth Turn-by-Turn Navigation & Multi-Design HUD App (turnByTurn.lua + hudapps.lua).
// 3 switchable designs: 'gmaps_card', 'round_minimap' (60-FPS HiDPI vector minimap), and 'ets_advisor'.
// Always visible (active route + idle cruise state), zero outer clipping, native BeamNG HUD tokens.
angular.module('beamng.apps')
.directive('beamngEarthNav', [function () {
  var FONT = 'font-family:"Overpass",var(--fnt-defs,sans-serif);'
  var NUM = 'font-variant-numeric:tabular-nums;'
  var CARD_BG = 'rgba(var(--bng-off-black-rgb,26,26,26),0.88)'
  var CTRL_BTN = 'background:rgba(16,20,27,0.88);color:var(--bng-off-white,#f4f6f8);' +
    'border:1px solid rgba(255,255,255,0.26);border-radius:var(--bng-corners-1,4px);' +
    'padding:3px 7px;font-size:10.5px;font-weight:700;cursor:pointer;line-height:1.15;' +
    'display:inline-flex;align-items:center;justify-content:center;gap:4px;' + FONT + NUM

  function svgPaths (varName, size) {
    return '<svg width="' + size + '" height="' + size + '" viewBox="0 0 24 24" fill="none" ' +
      'stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" ' +
      'style="display:block;flex-shrink:0;" ng-switch="' + varName + '">' +
      '<g ng-switch-when="turn_left"><path d="M16 20V11a3 3 0 0 0-3-3H6"/><polyline points="10 4 6 8 10 12"/></g>' +
      '<g ng-switch-when="turn_right"><path d="M8 20V11a3 3 0 0 1 3-3h7"/><polyline points="14 4 18 8 14 12"/></g>' +
      '<g ng-switch-when="slight_left"><path d="M15 20v-5.5a3 3 0 0 0-.88-2.12L8 6"/><polyline points="13 6 8 6 8 11"/></g>' +
      '<g ng-switch-when="slight_right"><path d="M9 20v-5.5a3 3 0 0 1 .88-2.12L16 6"/><polyline points="11 6 16 6 16 11"/></g>' +
      '<g ng-switch-when="sharp_left"><path d="M17 20V7a2 2 0 0 0-3.41-1.41L6 13.5"/><polyline points="6 8.5 6 13.5 11 13.5"/></g>' +
      '<g ng-switch-when="sharp_right"><path d="M7 20V7a2 2 0 0 1 3.41-1.41L18 13.5"/><polyline points="18 8.5 18 13.5 13 13.5"/></g>' +
      '<g ng-switch-when="uturn"><path d="M16 20V9a4 4 0 0 0-8 0v8"/><polyline points="4 13 8 17 12 13"/></g>' +
      '<g ng-switch-when="exit_right">' +
        '<path d="M8 20V5" opacity="0.45"/>' +
        '<path d="M8 15c0-3 2-5 6-7.5L18 5"/>' +
        '<polyline points="13.5 4.5 18 5 17.5 9.5"/>' +
      '</g>' +
      '<g ng-switch-when="exit_left">' +
        '<path d="M16 20V5" opacity="0.45"/>' +
        '<path d="M16 15c0-3-2-5-6-7.5L6 5"/>' +
        '<polyline points="10.5 4.5 6 5 6.5 9.5"/>' +
      '</g>' +
      '<g ng-switch-when="merge_left">' +
        '<path d="M10 20V5"/><polyline points="6 9 10 5 14 9"/>' +
        '<path d="M18 19c-2-2-4-4-8-8"/>' +
      '</g>' +
      '<g ng-switch-when="merge_right">' +
        '<path d="M14 20V5"/><polyline points="10 9 14 5 18 9"/>' +
        '<path d="M6 19c2-2 4-4 8-8"/>' +
      '</g>' +
      '<g ng-switch-when="roundabout">' +
        '<circle cx="12" cy="11" r="4"/>' +
        '<path d="M12 20v-5"/><path d="M15 8.5L19 5"/><polyline points="15 5 19 5 19 9"/>' +
      '</g>' +
      '<g ng-switch-when="arrive">' +
        '<path d="M12 21s-6-5.2-6-10a6 6 0 1 1 12 0c0 4.8-6 10-6 10z"/>' +
        '<circle cx="12" cy="11" r="2.2" fill="currentColor" stroke="none"/>' +
      '</g>' +
      '<g ng-switch-default><path d="M12 20V5"/><polyline points="7 10 12 5 17 10"/></g>' +
    '</svg>'
  }

  // Always-accessible, sharp control cluster (never vanishes on hover, never clipped)
  var CTRL_BAR =
    '<div class="bng-nav-ctrls" style="display:inline-flex;align-items:center;gap:4px;flex-shrink:0;">' +
      '<button type="button" ng-click="cycleDesign($event)" title="Switch navigation HUD design (Maps / Minimap / Advisor)" style="' + CTRL_BTN + '">' +
        '<span>{{ designBadge }}</span>' +
      '</button>' +
      '<button type="button" ng-click="toggleChime($event)" title="{{ nav.chimeEnabled ? \'Mute turn chimes\' : \'Enable turn chimes\' }}" style="' + CTRL_BTN + '">' +
        '<svg ng-if="nav.chimeEnabled" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">' +
          '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/>' +
        '</svg>' +
        '<svg ng-if="!nav.chimeEnabled" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">' +
          '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><line x1="22" y1="9" x2="16" y2="15"/><line x1="16" y1="9" x2="22" y2="15"/>' +
        '</svg>' +
      '</button>' +
    '</div>'

  // Generous 36px circular German/EU speed-limit sign
  var SPEED_SIGN =
    '<div ng-if="limitBadgeText" ' +
      'style="width:36px;height:36px;border-radius:50%;display:flex;align-items:center;justify-content:center;' +
      'font-size:13px;font-weight:800;line-height:1;flex-shrink:0;box-sizing:border-box;box-shadow:0 2px 6px rgba(0,0,0,0.45);' + NUM + '" ' +
      'ng-style="limitBadgeStyle">{{ limitBadgeText }}</div>'

  return {
    template:
      '<div class="bngApp" style="width:100%;height:100%;background:transparent;box-shadow:none;overflow:visible;' + FONT + '">' +

        // ============================================================
        // DESIGN 1: gmaps_card (Google Maps / CarPlay Turn Card — Always Visible)
        // ============================================================
        '<div ng-if="nav && nav.enabled && !hidden && nav.navDesign === \'gmaps_card\'" ' +
          'style="width:100%;border-radius:var(--bng-corners-2,8px);overflow:hidden;box-shadow:0 4px 16px rgba(0,0,0,0.48);border:1px solid rgba(255,255,255,0.14);">' +

          // ACTIVE ROUTE: High-contrast maneuver banner
          '<div ng-if="nav.active" ng-style="bannerStyle" style="position:relative;padding:10px 12px 12px;color:#ffffff;">' +
            '<div style="display:flex;align-items:flex-start;justify-content:space-between;gap:8px;">' +
              '<div style="display:flex;align-items:center;gap:11px;min-width:0;flex:1;">' +
                '<div style="width:42px;height:42px;border-radius:var(--bng-corners-1,6px);background:rgba(0,0,0,0.24);display:flex;align-items:center;justify-content:center;flex-shrink:0;">' +
                  svgPaths('nav.maneuver', 30) +
                '</div>' +
                '<div style="min-width:0;flex:1;">' +
                  '<div style="display:flex;align-items:baseline;gap:6px;">' +
                    '<span style="font-size:24px;font-weight:800;line-height:1.05;letter-spacing:-0.01em;' + NUM + '">{{ distText }}</span>' +
                    '<span ng-if="nav.isHighwayExit" style="font-size:10px;font-weight:800;letter-spacing:0.06em;text-transform:uppercase;padding:1px 5px;border-radius:3px;background:rgba(255,255,255,0.22);">EXIT</span>' +
                    '<span ng-if="nav.exitNum && !nav.isHighwayExit" style="font-size:10px;font-weight:800;letter-spacing:0.04em;text-transform:uppercase;padding:1px 5px;border-radius:3px;background:rgba(255,255,255,0.22);">EXIT {{ nav.exitNum }}</span>' +
                  '</div>' +
                  '<div style="font-size:14px;font-weight:700;line-height:1.25;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ primaryTitle }}</div>' +
                '</div>' +
              '</div>' +
              CTRL_BAR +
            '</div>' +
            '<div style="position:absolute;left:0;right:0;bottom:0;height:3px;background:rgba(0,0,0,0.28);">' +
              '<div ng-style="{width: progressPct + \'%\'}" style="height:100%;background:var(--bng-orange-b400,#ff6600);transition:width 160ms linear;"></div>' +
            '</div>' +
          '</div>' +

          // ACTIVE ROUTE: Compact "Then:" sub-bar
          '<div ng-if="nav.active && nav.nextManeuver" ng-style="subBannerStyle" ' +
            'style="display:flex;align-items:center;gap:6px;padding:5px 12px;color:rgba(255,255,255,0.92);font-size:11.5px;font-weight:600;border-top:1px solid rgba(255,255,255,0.12);">' +
            '<span style="opacity:0.78;text-transform:uppercase;font-size:10px;letter-spacing:0.05em;">Then</span>' +
            svgPaths('nav.nextManeuver', 15) +
            '<span style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ nav.nextStreetName || nextActionLabel }}</span>' +
          '</div>' +

          // ACTIVE ROUTE: Spacious bottom trip footer with 36px speed limit sign
          '<div ng-if="nav.active" style="display:flex;align-items:center;justify-content:space-between;gap:10px;padding:8px 12px;background:' + CARD_BG + ';color:var(--bng-off-white,#f0f0f0);font-size:12.5px;">' +
            '<div style="display:flex;align-items:center;gap:8px;min-width:0;flex-wrap:wrap;' + NUM + '">' +
              '<span style="font-weight:800;color:var(--bng-orange-b400,#ff6600);">{{ etaText }}</span>' +
              '<span style="opacity:0.4;">&middot;</span>' +
              '<span style="font-weight:700;">{{ remText }}</span>' +
              '<span style="opacity:0.4;">&middot;</span>' +
              '<span style="color:var(--bng-cool-gray-300,#b4b8c2);">{{ arrivalClock }}</span>' +
            '</div>' +
            SPEED_SIGN +
          '</div>' +

          // IDLE CRUISE STATE (Always visible when no route is active)
          '<div ng-if="!nav.active" style="padding:10px 12px;background:' + CARD_BG + ';color:var(--bng-off-white,#f0f0f0);">' +
            '<div style="display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:8px;">' +
              '<div style="display:flex;align-items:center;gap:6px;' + NUM + '">' +
                '<span style="color:var(--bng-orange-b400,#ff6600);font-size:11px;font-weight:800;letter-spacing:0.05em;">{{ cardinalText }}</span>' +
                '<span style="font-size:11px;color:var(--bng-cool-gray-300,#b4b8c2);">{{ headingText }}</span>' +
                '<span style="opacity:0.35;">|</span>' +
                '<span style="font-size:11px;font-weight:700;color:var(--bng-cool-gray-200,#d4d8e0);">{{ speedText }}</span>' +
              '</div>' +
              CTRL_BAR +
            '</div>' +
            '<div style="display:flex;align-items:center;justify-content:space-between;gap:12px;">' +
              '<div style="min-width:0;flex:1;">' +
                '<div style="font-size:14px;font-weight:700;line-height:1.25;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ cruiseTitle }}</div>' +
                '<div style="font-size:11.5px;color:var(--bng-cool-gray-300,#b4b8c2);margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ cruiseSub }}</div>' +
              '</div>' +
              SPEED_SIGN +
            '</div>' +
          '</div>' +
        '</div>' +

        // ============================================================
        // DESIGN 2: round_minimap (60-FPS HiDPI Circular Minimap + Docked Header, Zero Clipping)
        // ============================================================
        '<div ng-if="nav && nav.enabled && !hidden && nav.navDesign === \'round_minimap\'" ' +
          'style="display:flex;flex-direction:column;align-items:center;width:244px;margin:0 auto;overflow:visible;">' +

          // Floating top control pill bar — OUTSIDE the circle, never clipped
          '<div style="width:236px;display:flex;align-items:center;justify-content:space-between;gap:6px;margin-bottom:5px;">' +
            '<div style="padding:2px 8px;border-radius:var(--bng-corners-1,4px);background:rgba(16,20,27,0.86);border:1px solid rgba(255,255,255,0.18);color:#e4e8ef;font-size:10.5px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:146px;' + NUM + '">' +
              '{{ nav.active ? (nav.isHighwayExit ? "AUTOBAHN EXIT" : "NAVIGATION") : (cardinalText + " " + headingText + " · " + speedText) }}' +
            '</div>' +
            CTRL_BAR +
          '</div>' +

          // Docked compact turn-by-turn banner (when active) OR compact street pill (when idle)
          '<div ng-if="nav.active" ng-style="bannerStyle" ' +
            'style="position:relative;width:236px;border-radius:var(--bng-corners-2,8px);padding:7px 10px 9px;color:#ffffff;box-shadow:0 3px 12px rgba(0,0,0,0.48);border:1px solid rgba(255,255,255,0.18);margin-bottom:6px;z-index:3;overflow:hidden;">' +
            '<div style="display:flex;align-items:center;gap:9px;">' +
              svgPaths('nav.maneuver', 24) +
              '<div style="min-width:0;flex:1;">' +
                '<div style="display:flex;align-items:baseline;justify-content:space-between;gap:6px;">' +
                  '<span style="font-size:17px;font-weight:800;line-height:1.05;' + NUM + '">{{ distText }}</span>' +
                  '<span style="font-size:10.5px;font-weight:700;opacity:0.9;' + NUM + '">{{ etaText }}</span>' +
                '</div>' +
                '<div style="font-size:12px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:1px;">{{ primaryTitle }}</div>' +
              '</div>' +
            '</div>' +
            '<div style="position:absolute;left:0;right:0;bottom:0;height:2.5px;background:rgba(0,0,0,0.3);">' +
              '<div ng-style="{width: progressPct + \'%\'}" style="height:100%;background:var(--bng-orange-b400,#ff6600);"></div>' +
            '</div>' +
          '</div>' +

          // Circular map container: outer wrapper is overflow:visible so speed sign & bottom pill are NEVER clipped
          '<div style="position:relative;width:196px;height:196px;overflow:visible;flex-shrink:0;">' +
            // Circular clipping applies ONLY to the translucent canvas shell (no opaque fill)
            '<div style="width:196px;height:196px;border-radius:50%;overflow:hidden;background:transparent;border:2px solid rgba(255,255,255,0.22);box-shadow:0 4px 18px rgba(0,0,0,0.45);box-sizing:border-box;">' +
              '<canvas class="bng-nav-minimap-canvas" width="196" height="196" style="width:196px;height:196px;display:block;"></canvas>' +
            '</div>' +

            // 36px speed limit sign positioned cleanly on the lower-left rim (unclipped!)
            '<div ng-if="limitBadgeText" style="position:absolute;bottom:8px;left:-8px;z-index:4;">' +
              SPEED_SIGN +
            '</div>' +

            // Bottom distance / street pill (flex-centered without subpixel transform blur)
            '<div style="position:absolute;left:0;right:0;bottom:-6px;display:flex;justify-content:center;pointer-events:none;z-index:4;">' +
              '<div style="max-width:170px;padding:3px 10px;border-radius:11px;background:rgba(15,18,24,0.88);border:1px solid rgba(255,255,255,0.2);color:#f4f6f8;font-size:11px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;box-shadow:0 2px 8px rgba(0,0,0,0.45);' + NUM + '">' +
                '{{ nav.active ? (remText + " · " + etaText) : cruiseTitle }}' +
              '</div>' +
            '</div>' +
          '</div>' +
        '</div>' +

        // ============================================================
        // DESIGN 3: ets_advisor (ETS2 / Truck Cockpit Route Advisor — Always Visible)
        // ============================================================
        '<div ng-if="nav && nav.enabled && !hidden && nav.navDesign === \'ets_advisor\'" ' +
          'style="width:100%;min-width:316px;background:' + CARD_BG + ';color:var(--bng-off-white,#f0f0f0);border-radius:var(--bng-corners-1,4px);border:1px solid rgba(255,255,255,0.15);box-shadow:0 4px 16px rgba(0,0,0,0.5);overflow:hidden;">' +
          // Top compass / heading strip
          '<div style="display:flex;align-items:center;justify-content:space-between;gap:8px;padding:5px 10px;background:rgba(0,0,0,0.36);border-bottom:1px solid rgba(255,255,255,0.1);font-size:11px;">' +
            '<div style="display:flex;align-items:center;gap:6px;min-width:0;' + NUM + '">' +
              '<span style="color:var(--bng-orange-b400,#ff6600);font-weight:800;letter-spacing:0.05em;">{{ cardinalText }}</span>' +
              '<span style="color:var(--bng-cool-gray-300,#b4b8c2);">{{ headingText }}</span>' +
              '<span style="opacity:0.35;">|</span>' +
              '<span style="max-width:140px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:var(--bng-cool-gray-200,#d4d8e0);">{{ cruiseTitle }}</span>' +
            '</div>' +
            CTRL_BAR +
          '</div>' +

          // Main advisor telemetry row
          '<div style="display:flex;align-items:center;gap:10px;padding:9px 11px;">' +
            // Generous 36px speed limit sign (or neutral placeholder when unknown)
            '<div style="width:36px;height:36px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:800;line-height:1;flex-shrink:0;box-sizing:border-box;' + NUM + '" ng-style="limitBadgeStyle">{{ limitBadgeText || "--" }}</div>' +

            // Next maneuver + street name
            '<div style="display:flex;align-items:center;gap:9px;flex:1;min-width:0;">' +
              '<div ng-if="nav.active" ng-style="bannerStyle" style="width:36px;height:36px;border-radius:var(--bng-corners-1,4px);display:flex;align-items:center;justify-content:center;color:#fff;flex-shrink:0;">' +
                svgPaths('nav.maneuver', 23) +
              '</div>' +
              '<div style="min-width:0;flex:1;">' +
                '<div ng-if="nav.active" style="display:flex;align-items:baseline;gap:6px;">' +
                  '<span style="font-size:18px;font-weight:800;line-height:1.05;' + NUM + '">{{ distText }}</span>' +
                  '<span ng-if="nav.isHighwayExit" style="font-size:9.5px;font-weight:800;padding:1px 5px;border-radius:2px;background:#0b4f8c;color:#fff;letter-spacing:0.05em;">EXIT</span>' +
                '</div>' +
                '<div ng-if="!nav.active" style="font-size:11.5px;font-weight:700;color:var(--bng-cool-gray-300,#b4b8c2);">Cruise · Free Drive</div>' +
                '<div style="font-size:12.5px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:#f4f6f8;">{{ nav.active ? primaryTitle : cruiseSub }}</div>' +
                '<div ng-if="nav.active" style="height:2.5px;background:rgba(255,255,255,0.14);border-radius:2px;margin-top:4px;overflow:hidden;">' +
                  '<div ng-style="{width: progressPct + \'%\'}" style="height:100%;background:var(--bng-orange-b400,#ff6600);"></div>' +
                '</div>' +
              '</div>' +
            '</div>' +

            // Right remaining distance / ETA column
            '<div style="text-align:right;flex-shrink:0;padding-left:9px;border-left:1px solid rgba(255,255,255,0.12);' + NUM + '">' +
              '<div style="font-size:13.5px;font-weight:800;color:var(--bng-orange-b400,#ff6600);">{{ nav.active ? etaText : speedText }}</div>' +
              '<div style="font-size:11px;font-weight:600;color:var(--bng-cool-gray-300,#b4b8c2);">{{ nav.active ? remText : "CRUISE" }}</div>' +
            '</div>' +
          '</div>' +
        '</div>' +

      '</div>',
    replace: true,
    link: function (scope, element) {
      'use strict'
      scope.nav = null
      scope.hidden = false
      scope.distText = '--'
      scope.remText = '--'
      scope.etaText = '--'
      scope.arrivalClock = '--:--'
      scope.primaryTitle = ''
      scope.nextActionLabel = ''
      scope.cruiseTitle = 'Free Drive'
      scope.cruiseSub = 'Set a destination on Map'
      scope.progressPct = 0
      scope.designBadge = '1/3'
      scope.cardinalText = 'N'
      scope.headingText = '000°'
      scope.speedText = '0 km/h'
      scope.limitBadgeText = ''
      scope.limitBadgeStyle = { background: '#262b33', color: '#9aa2b0', border: '2px solid #48515e' }
      scope.bannerStyle = { background: '#14532d' }
      scope.subBannerStyle = { background: '#0e3c20' }

      var lastChimeSeq = -1
      var audioCtx = null

      // High-FPS pose & smooth interpolation state for 60-FPS requestAnimationFrame loop
      var poseInitialized = false
      var targetPose = { x: 0, y: 0, vehHeadingRad: 0, camHeadingRad: 0, speedKph: 0 }
      var renderPose = { x: 0, y: 0, vehHeadingRad: 0, camHeadingRad: 0, speedKph: 0 }
      var rafId = null
      var lastRafMs = 0
      var cachedCanvas = null
      var cachedDpr = 0
      var lastHudTextPoseMs = 0

      var ACTION_LABELS = {
        turn_left: 'Turn left',
        turn_right: 'Turn right',
        slight_left: 'Keep left',
        slight_right: 'Keep right',
        sharp_left: 'Sharp left',
        sharp_right: 'Sharp right',
        uturn: 'Make a U-turn',
        exit_right: 'Take exit right',
        exit_left: 'Take exit left',
        merge_left: 'Merge left',
        merge_right: 'Merge right',
        roundabout: 'Enter roundabout',
        straight: 'Continue straight',
        arrive: 'Arrive at destination'
      }

      var CARDINALS = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW']

      function unclip () {
        var el = element && element[0]
        var host = el && el.closest ? el.closest('.ui-app-host') : null
        if (host) host.style.overflow = 'visible'
      }

      function formatDist (m, units) {
        var val = Math.max(0, Number(m) || 0)
        if (units === 'imperial') {
          var ft = val * 3.28084
          if (ft < 1000) return Math.max(10, Math.round(ft / 10) * 10) + ' ft'
          var mi = val / 1609.344
          return (mi >= 10 ? Math.round(mi) : mi.toFixed(1)) + ' mi'
        }
        if (val < 1000) {
          if (val >= 100) return (Math.round(val / 10) * 10) + ' m'
          if (val >= 20) return (Math.round(val / 5) * 5) + ' m'
          return Math.round(val) + ' m'
        }
        var km = val / 1000
        return (km >= 10 ? Math.round(km) : km.toFixed(1)) + ' km'
      }

      function formatEta (sec) {
        var s = Math.max(0, Math.round(Number(sec) || 0))
        if (s < 60) return '< 1 min'
        var mins = Math.round(s / 60)
        if (mins < 60) return mins + ' min'
        var h = Math.floor(mins / 60)
        var r = mins % 60
        return h + 'h ' + (r < 10 ? '0' : '') + r + 'm'
      }

      function formatArrival (sec) {
        var d = new Date(Date.now() + Math.max(0, Number(sec) || 0) * 1000)
        var hh = d.getHours()
        var mm = d.getMinutes()
        return (hh < 10 ? '0' : '') + hh + ':' + (mm < 10 ? '0' : '') + mm
      }

      function formatHeadingFields (hdgDeg, speedKph, units) {
        var hdg = ((Number(hdgDeg) || 0) % 360 + 360) % 360
        scope.headingText = (hdg < 10 ? '00' : (hdg < 100 ? '0' : '')) + Math.round(hdg) + '°'
        scope.cardinalText = CARDINALS[Math.round(hdg / 45) % 8]
        scope.speedText = (units === 'imperial'
          ? Math.round((Number(speedKph) || 0) * 0.621371) + ' mph'
          : Math.round(Number(speedKph) || 0) + ' km/h')
      }

      function shortestAngleDiff (fromRad, toRad) {
        var diff = (toRad - fromRad) % (Math.PI * 2)
        if (diff > Math.PI) diff -= Math.PI * 2
        if (diff < -Math.PI) diff += Math.PI * 2
        return diff
      }

      // Lightweight WebAudio chime (no external audio files)
      function playChime (kind) {
        try {
          var Ctx = window.AudioContext || window.webkitAudioContext
          if (!Ctx) return
          if (!audioCtx) audioCtx = new Ctx()
          if (audioCtx.state === 'suspended' && audioCtx.resume) audioCtx.resume()
          var t0 = audioCtx.currentTime
          var notes = [[660, 0.0, 0.12, 0.07]]
          if (kind === 'exit_far') {
            notes = [[587.33, 0.0, 0.11, 0.06], [783.99, 0.13, 0.14, 0.07]]
          } else if (kind === 'exit_near') {
            notes = [[783.99, 0.0, 0.09, 0.08], [987.77, 0.11, 0.13, 0.09]]
          } else if (kind === 'arrive') {
            notes = [[523.25, 0.0, 0.12, 0.07], [659.25, 0.14, 0.18, 0.08]]
          }
          for (var i = 0; i < notes.length; i++) {
            var n = notes[i]
            var osc = audioCtx.createOscillator()
            var gain = audioCtx.createGain()
            osc.type = 'sine'
            osc.frequency.setValueAtTime(n[0], t0 + n[1])
            gain.gain.setValueAtTime(0.0001, t0 + n[1])
            gain.gain.exponentialRampToValueAtTime(n[3], t0 + n[1] + 0.015)
            gain.gain.exponentialRampToValueAtTime(0.0001, t0 + n[1] + n[2])
            osc.connect(gain)
            gain.connect(audioCtx.destination)
            osc.start(t0 + n[1])
            osc.stop(t0 + n[1] + n[2] + 0.02)
          }
        } catch (e) {}
      }

      // 60-FPS HiDPI Canvas renderer for 'round_minimap' (native glass backdrop, camera-pan rotation, zero-lag route)
      function drawRoundMinimap () {
        var nav = scope.nav
        if (!nav || !nav.enabled || scope.hidden || nav.navDesign !== 'round_minimap') return
        var el = element && element[0]
        if (!el) return
        if (!cachedCanvas || !cachedCanvas.isConnected) {
          cachedCanvas = el.querySelector('.bng-nav-minimap-canvas')
          cachedDpr = 0
        }
        var canvas = cachedCanvas
        if (!canvas || !canvas.getContext) return

        var cssSize = 196
        var dpr = Math.min(3, window.devicePixelRatio || 1)
        if (cachedDpr !== dpr) {
          canvas.width = Math.round(cssSize * dpr)
          canvas.height = Math.round(cssSize * dpr)
          cachedDpr = dpr
        }

        var ctx = canvas.getContext('2d')
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0)

        var w = cssSize
        var h = cssSize
        var cx = w * 0.5
        var cy = h * 0.54
        var radius = w * 0.5

        var spd = renderPose.speedKph
        var viewM = Math.max(155, Math.min(380, 155 + spd * 1.7))
        var pxPerM = (w * 0.46) / viewM
        var mapRot = nav.northUp ? 0 : -renderPose.camHeadingRad
        var arrowRot = nav.northUp
          ? renderPose.vehHeadingRad
          : (renderPose.vehHeadingRad - renderPose.camHeadingRad)
        var cosR = Math.cos(mapRot)
        var sinR = Math.sin(mapRot)
        var px = renderPose.x
        var py = renderPose.y

        ctx.clearRect(0, 0, w, h)
        ctx.save()
        ctx.beginPath()
        ctx.arc(w * 0.5, h * 0.5, radius, 0, Math.PI * 2)
        ctx.clip()

        // Semi-transparent dark glass backdrop matching native BeamNG minimap
        ctx.fillStyle = 'rgba(16, 19, 24, 0.58)'
        ctx.fillRect(0, 0, w, h)

        // Full road network (two-pass: dark casings, then native road fills by class)
        var roads = nav.miniRoads
        if (Array.isArray(roads) && roads.length >= 5) {
          ctx.lineCap = 'round'
          ctx.lineJoin = 'round'

          // Pass 1: dark translucent road casings
          ctx.strokeStyle = 'rgba(0, 0, 0, 0.72)'
          for (var i = 0; i < roads.length; i += 5) {
            var dx1 = roads[i] - px
            var dy1 = roads[i + 1] - py
            var dx2 = roads[i + 2] - px
            var dy2 = roads[i + 3] - py
            var cls = roads[i + 4]
            var sx1 = cx + (dx1 * cosR - dy1 * sinR) * pxPerM
            var sy1 = cy - (dx1 * sinR + dy1 * cosR) * pxPerM
            var sx2 = cx + (dx2 * cosR - dy2 * sinR) * pxPerM
            var sy2 = cy - (dx2 * sinR + dy2 * cosR) * pxPerM
            ctx.lineWidth = cls === 0 ? 7.2 : (cls === 1 ? 5.6 : (cls === 2 ? 4.0 : 2.8))
            ctx.beginPath()
            ctx.moveTo(sx1, sy1)
            ctx.lineTo(sx2, sy2)
            ctx.stroke()
          }

          // Pass 2: road fills by drivability/highway class
          for (var j = 0; j < roads.length; j += 5) {
            var rdx1 = roads[j] - px
            var rdy1 = roads[j + 1] - py
            var rdx2 = roads[j + 2] - px
            var rdy2 = roads[j + 3] - py
            var rcls = roads[j + 4]
            var rsx1 = cx + (rdx1 * cosR - rdy1 * sinR) * pxPerM
            var rsy1 = cy - (rdx1 * sinR + rdy1 * cosR) * pxPerM
            var rsx2 = cx + (rdx2 * cosR - rdy2 * sinR) * pxPerM
            var rsy2 = cy - (rdx2 * sinR + rdy2 * cosR) * pxPerM
            if (rcls === 0) {
              ctx.strokeStyle = 'rgba(232, 237, 245, 0.92)'
              ctx.lineWidth = 4.8
            } else if (rcls === 1) {
              ctx.strokeStyle = 'rgba(206, 214, 226, 0.86)'
              ctx.lineWidth = 3.5
            } else if (rcls === 2) {
              ctx.strokeStyle = 'rgba(154, 164, 178, 0.72)'
              ctx.lineWidth = 2.2
            } else {
              ctx.strokeStyle = 'rgba(128, 118, 104, 0.62)'
              ctx.lineWidth = 1.4
            }
            ctx.beginPath()
            ctx.moveTo(rsx1, rsy1)
            ctx.lineTo(rsx2, rsy2)
            ctx.stroke()
          }
        }

        // Zero-Lag Signature BeamNG.Earth Blue Route Line with Crisp White Casing:
        // Project (px, py) onto closest route segment and trim passed vertices at 60 FPS.
        var rpts = nav.miniRoute
        if (Array.isArray(rpts) && rpts.length >= 4) {
          var bestSeg = 0
          var bestDistSq = Infinity
          var projX = rpts[0]
          var projY = rpts[1]
          for (var s = 0; s < rpts.length - 2; s += 2) {
            var ax = rpts[s]
            var ay = rpts[s + 1]
            var bx = rpts[s + 2]
            var by = rpts[s + 3]
            var abx = bx - ax
            var aby = by - ay
            var l2 = abx * abx + aby * aby
            var t = l2 > 1e-6 ? Math.max(0, Math.min(1, ((px - ax) * abx + (py - ay) * aby) / l2)) : 0
            var qx = ax + t * abx
            var qy = ay + t * aby
            var d2 = (qx - px) * (qx - px) + (qy - py) * (qy - py)
            if (d2 < bestDistSq) {
              bestDistSq = d2
              bestSeg = s
              projX = qx
              projY = qy
            }
          }

          // Start directly at player position when within 14 m of route so line never lags behind chevron
          var startX = bestDistSq <= 196 ? px : projX
          var startY = bestDistSq <= 196 ? py : projY

          ctx.lineCap = 'round'
          ctx.lineJoin = 'round'
          ctx.beginPath()
          var srx = startX - px
          var sry = startY - py
          ctx.moveTo(cx + (srx * cosR - sry * sinR) * pxPerM, cy - (srx * sinR + sry * cosR) * pxPerM)
          for (var k = bestSeg + 2; k < rpts.length; k += 2) {
            var rrx = rpts[k] - px
            var rry = rpts[k + 1] - py
            var psx = cx + (rrx * cosR - rry * sinR) * pxPerM
            var psy = cy - (rrx * sinR + rry * cosR) * pxPerM
            ctx.lineTo(psx, psy)
          }
          // Outer dark shadow for contrast
          ctx.strokeStyle = 'rgba(0, 0, 0, 0.42)'
          ctx.lineWidth = 11.0
          ctx.stroke()
          // Crisp white border casing
          ctx.strokeStyle = '#ffffff'
          ctx.lineWidth = 8.4
          ctx.stroke()
          // Signature BeamNG.Earth navigation blue
          ctx.strokeStyle = '#1a8cff'
          ctx.lineWidth = 5.2
          ctx.stroke()
        }

        // Sleek rounded orange-with-crisp-white-border player chevron (rotated relative to camera!)
        ctx.save()
        ctx.translate(cx, cy)
        ctx.rotate(arrowRot)
        ctx.shadowColor = 'rgba(0, 0, 0, 0.5)'
        ctx.shadowBlur = 4
        ctx.shadowOffsetY = 1
        ctx.fillStyle = '#ff6600'
        ctx.strokeStyle = '#ffffff'
        ctx.lineWidth = 2.2
        ctx.lineJoin = 'round'
        ctx.beginPath()
        ctx.moveTo(0, -10.5)
        ctx.quadraticCurveTo(2.4, -5.0, 7.6, 6.2)
        ctx.quadraticCurveTo(8.2, 8.2, 6.2, 7.4)
        ctx.quadraticCurveTo(1.6, 4.6, 0, 4.4)
        ctx.quadraticCurveTo(-1.6, 4.6, -6.2, 7.4)
        ctx.quadraticCurveTo(-8.2, 8.2, -7.6, 6.2)
        ctx.quadraticCurveTo(-2.4, -5.0, 0, -10.5)
        ctx.closePath()
        ctx.fill()
        ctx.shadowColor = 'transparent'
        ctx.stroke()
        ctx.restore()

        // North compass marker on inner rim (rotates with camera pan)
        var nx = w * 0.5 + Math.sin(mapRot) * (radius - 13)
        var ny = h * 0.5 - Math.cos(mapRot) * (radius - 13)
        ctx.fillStyle = 'rgba(15, 18, 24, 0.78)'
        ctx.beginPath()
        ctx.arc(nx, ny, 8.5, 0, Math.PI * 2)
        ctx.fill()
        ctx.fillStyle = '#ff6600'
        ctx.font = '800 10px Overpass, sans-serif'
        ctx.textAlign = 'center'
        ctx.textBaseline = 'middle'
        ctx.fillText('N', nx, ny + 0.5)

        ctx.restore()
      }

      function rafStep (nowMs) {
        rafId = null
        var nav = scope.nav
        if (!nav || !nav.enabled || scope.hidden || nav.navDesign !== 'round_minimap') return

        var dt = lastRafMs > 0 ? Math.min(0.1, Math.max(0.001, (nowMs - lastRafMs) / 1000)) : 0.016
        lastRafMs = nowMs

        var dx = targetPose.x - renderPose.x
        var dy = targetPose.y - renderPose.y
        if (dx * dx + dy * dy > 14400) {
          renderPose.x = targetPose.x
          renderPose.y = targetPose.y
          renderPose.vehHeadingRad = targetPose.vehHeadingRad
          renderPose.camHeadingRad = targetPose.camHeadingRad
          renderPose.speedKph = targetPose.speedKph
        } else {
          var alpha = 1 - Math.exp(-dt * 20)
          renderPose.x += dx * alpha
          renderPose.y += dy * alpha
          renderPose.vehHeadingRad += shortestAngleDiff(renderPose.vehHeadingRad, targetPose.vehHeadingRad) * alpha
          renderPose.camHeadingRad += shortestAngleDiff(renderPose.camHeadingRad, targetPose.camHeadingRad) * alpha
          renderPose.speedKph += (targetPose.speedKph - renderPose.speedKph) * alpha
        }

        drawRoundMinimap()
        rafId = window.requestAnimationFrame(rafStep)
      }

      function syncRafLoop () {
        var want = !!(scope.nav && scope.nav.enabled && !scope.hidden && scope.nav.navDesign === 'round_minimap')
        if (want && !rafId) {
          lastRafMs = 0
          rafId = window.requestAnimationFrame(rafStep)
        } else if (!want && rafId) {
          window.cancelAnimationFrame(rafId)
          rafId = null
        }
      }

      function applyNav (nav) {
        scope.nav = nav || null
        if (!nav) {
          syncRafLoop()
          return
        }

        var design = nav.navDesign || 'gmaps_card'
        scope.designBadge = design === 'gmaps_card' ? '1/3' : (design === 'round_minimap' ? '2/3' : '3/3')

        if (nav.isHighwayExit) {
          scope.bannerStyle = { background: '#0b4f8c' }
          scope.subBannerStyle = { background: '#073966' }
        } else {
          scope.bannerStyle = { background: '#14532d' }
          scope.subBannerStyle = { background: '#0d3b20' }
        }

        scope.distText = formatDist(nav.distToTurnM, nav.units)
        scope.remText = formatDist(nav.remainingM, nav.units)
        scope.etaText = formatEta(nav.etaSec)
        scope.arrivalClock = formatArrival(nav.etaSec)
        scope.progressPct = Math.max(0, Math.min(100, Math.round((Number(nav.approachProgress) || 0) * 100)))

        var fallbackAction = ACTION_LABELS[nav.maneuver] || 'Continue'
        scope.primaryTitle = nav.streetName || nav.destName || fallbackAction
        scope.nextActionLabel = ACTION_LABELS[nav.nextManeuver] || ''

        // Always-visible cruise labels
        scope.cruiseTitle = nav.currentStreet || nav.currentPlace || nav.coordsLabel || 'Free Drive'
        if (nav.currentStreet && nav.currentPlace) {
          scope.cruiseSub = nav.currentPlace
        } else if (nav.coordsLabel) {
          scope.cruiseSub = nav.coordsLabel
        } else {
          scope.cruiseSub = 'Set a destination on Map'
        }

        // Seed pose from HUD payload if 60-Hz pose hasn't arrived yet
        if (!poseInitialized && nav.playerX != null && nav.playerY != null) {
          poseInitialized = true
          targetPose.x = renderPose.x = Number(nav.playerX) || 0
          targetPose.y = renderPose.y = Number(nav.playerY) || 0
          var vr = Number(nav.vehHeadingRad != null ? nav.vehHeadingRad : nav.headingRad)
          if (isNaN(vr)) vr = ((Number(nav.headingDeg) || 0) * Math.PI) / 180
          var cr = Number(nav.camHeadingRad != null ? nav.camHeadingRad : vr)
          if (isNaN(cr)) cr = vr
          targetPose.vehHeadingRad = renderPose.vehHeadingRad = vr
          targetPose.camHeadingRad = renderPose.camHeadingRad = cr
          targetPose.speedKph = renderPose.speedKph = Number(nav.speedKph) || 0
        }

        formatHeadingFields(nav.headingDeg, nav.speedKph, nav.units)

        // Speed limit badge styling (generous 36px German/EU sign)
        if (nav.speedLimitUnlimited) {
          scope.limitBadgeText = '///'
          scope.limitBadgeStyle = { background: '#e5e7eb', color: '#374151', border: '3px solid #4b5563' }
        } else if (nav.speedLimitKph != null && nav.speedLimitKph > 0) {
          var dispLim = nav.units === 'imperial'
            ? Math.round(nav.speedLimitKph * 0.621371)
            : Math.round(nav.speedLimitKph)
          scope.limitBadgeText = String(dispLim)
          scope.limitBadgeStyle = { background: '#ffffff', color: '#111827', border: '3.5px solid #d92d20' }
        } else {
          scope.limitBadgeText = ''
          scope.limitBadgeStyle = { background: '#262b33', color: '#9aa2b0', border: '2px solid #48515e' }
        }

        // Chime trigger
        var seq = Number(nav.chimeSeq) || 0
        if (lastChimeSeq >= 0 && seq > lastChimeSeq && nav.chimeEnabled) {
          playChime(nav.chimeKind)
        }
        lastChimeSeq = seq

        syncRafLoop()
      }

      scope.cycleDesign = function ($event) {
        if ($event && $event.stopPropagation) $event.stopPropagation()
        bngApi.engineLua('if beamngEarth_turnByTurn then beamngEarth_turnByTurn.cycleDesign() end')
      }

      scope.toggleChime = function ($event) {
        if ($event && $event.stopPropagation) $event.stopPropagation()
        var nextVal = (scope.nav && scope.nav.chimeEnabled) ? 'false' : 'true'
        bngApi.engineLua('if beamngEarth_turnByTurn then beamngEarth_turnByTurn.setChimeEnabled(' + nextVal + ') end')
      }

      unclip()
      bngApi.engineLua('if beamngEarth_core then beamngEarth_core.hudApp("nav", true) end')
      bngApi.engineLua('if beamngEarth_turnByTurn and beamngEarth_turnByTurn.uiState then return beamngEarth_turnByTurn.uiState() end', function (st) {
        if (st && typeof st === 'object') {
          scope.$evalAsync(function () { applyNav(st) })
        }
      })

      // 4-Hz full navigation + road network payload
      scope.$on('BeamNGEarthHud', function (_, data) {
        if (!data) return
        scope.$evalAsync(function () {
          scope.hidden = !!data.hidden
          applyNav(data.nav)
        })
      })

      // 60-Hz lightweight pose feed for buttery-smooth canvas rotation & panning
      scope.$on('BeamNGEarthNavPose', function (_, pose) {
        if (!pose) return
        targetPose.x = Number(pose.x) || 0
        targetPose.y = Number(pose.y) || 0
        var vr = Number(pose.vehHeadingRad != null ? pose.vehHeadingRad : pose.headingRad) || 0
        var cr = Number(pose.camHeadingRad != null ? pose.camHeadingRad : vr)
        if (isNaN(cr)) cr = vr
        targetPose.vehHeadingRad = vr
        targetPose.camHeadingRad = cr
        targetPose.speedKph = Number(pose.speedKph) || 0
        if (!poseInitialized) {
          poseInitialized = true
          renderPose.x = targetPose.x
          renderPose.y = targetPose.y
          renderPose.vehHeadingRad = targetPose.vehHeadingRad
          renderPose.camHeadingRad = targetPose.camHeadingRad
          renderPose.speedKph = targetPose.speedKph
        }
        // Keep text compass/speed crisp at ~12 Hz without overloading Angular $digest
        var now = Date.now()
        if (scope.nav && (now - lastHudTextPoseMs) >= 80) {
          lastHudTextPoseMs = now
          scope.$evalAsync(function () {
            formatHeadingFields(pose.headingDeg, pose.speedKph, scope.nav && scope.nav.units)
          })
        }
      })

      scope.$on('$destroy', function () {
        if (rafId) {
          window.cancelAnimationFrame(rafId)
          rafId = null
        }
        bngApi.engineLua('if beamngEarth_core then beamngEarth_core.hudApp("nav", false) end')
        if (audioCtx && audioCtx.close) {
          try { audioCtx.close() } catch (e) {}
        }
      })
    }
  }
}])
