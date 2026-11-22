// BeamNG.Earth Turn-by-Turn Navigation & Multi-Design HUD App (turnByTurn.lua + hudapps.lua).
// Pure vector <svg> 60-FPS round_minimap + gmaps_card + ets_advisor.
// Zero box-shadow/text-shadow/filter (crisp CEF rendering, zero dark halo), always visible, zero clipping.
angular.module('beamng.apps')
.directive('beamngEarthNav', [function () {
  var FONT = 'font-family:"Overpass",var(--fnt-defs,sans-serif);'
  var NUM = 'font-variant-numeric:tabular-nums;'
  var CARD_BG = 'rgba(var(--bng-off-black-rgb,26,26,26),0.86)'
  var CTRL_BTN = 'background:rgba(15,18,22,0.82);color:var(--bng-off-white,#f4f6f8);' +
    'border:1px solid rgba(255,255,255,0.22);border-radius:var(--bng-corners-1,4px);' +
    'padding:2px 6px;font-size:10px;font-weight:700;cursor:pointer;line-height:1.15;' +
    'display:inline-flex;align-items:center;justify-content:center;gap:3px;' + FONT + NUM

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

  // Crisp pure-vector circular German/EU speed-limit SVG sign
  function speedSignSvg (sizePx) {
    return '<svg ng-if="limitBadgeText" width="' + sizePx + '" height="' + sizePx + '" viewBox="0 0 36 36" style="display:block;flex-shrink:0;">' +
      '<circle cx="18" cy="18" r="16" ng-attr-fill="{{ limitSvgFill }}" ng-attr-stroke="{{ limitSvgStroke }}" stroke-width="3.2"/>' +
      '<text x="18" y="18.6" text-anchor="middle" dominant-baseline="central" ng-attr-fill="{{ limitSvgText }}" ' +
        'font-family="Overpass, sans-serif" font-size="13.5" font-weight="800">{{ limitBadgeText }}</text>' +
    '</svg>'
  }

  var CTRL_BAR =
    '<div class="bng-nav-ctrls" style="display:inline-flex;align-items:center;gap:4px;flex-shrink:0;">' +
      '<button type="button" ng-click="cycleDesign($event)" title="Switch navigation HUD design (Maps / Minimap / Advisor)" style="' + CTRL_BTN + '">' +
        '<span>{{ designBadge }}</span>' +
      '</button>' +
      '<button type="button" ng-click="toggleChime($event)" title="{{ nav.chimeEnabled ? \'Mute turn chimes\' : \'Enable turn chimes\' }}" style="' + CTRL_BTN + '">' +
        '<svg ng-if="nav.chimeEnabled" width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">' +
          '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/>' +
        '</svg>' +
        '<svg ng-if="!nav.chimeEnabled" width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">' +
          '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><line x1="22" y1="9" x2="16" y2="15"/><line x1="16" y1="9" x2="22" y2="15"/>' +
        '</svg>' +
      '</button>' +
    '</div>'

  return {
    template:
      '<div class="bngApp" style="width:100%;height:100%;background:transparent;overflow:visible;' + FONT + '">' +

        // ============================================================
        // DESIGN 1: gmaps_card (Google Maps / CarPlay Turn Card — Always Visible, Zero Shadow)
        // ============================================================
        '<div ng-if="nav && nav.enabled && !hidden && nav.navDesign === \'gmaps_card\'" ' +
          'style="width:100%;border-radius:var(--bng-corners-2,8px);overflow:hidden;border:1px solid rgba(255,255,255,0.16);">' +

          // ACTIVE ROUTE: High-contrast maneuver banner
          '<div ng-if="nav.active" ng-style="bannerStyle" style="position:relative;padding:9px 11px 11px;color:#ffffff;">' +
            '<div style="display:flex;align-items:flex-start;justify-content:space-between;gap:8px;">' +
              '<div style="display:flex;align-items:center;gap:10px;min-width:0;flex:1;">' +
                '<div style="width:40px;height:40px;border-radius:var(--bng-corners-1,6px);background:rgba(0,0,0,0.22);display:flex;align-items:center;justify-content:center;flex-shrink:0;">' +
                  svgPaths('nav.maneuver', 28) +
                '</div>' +
                '<div style="min-width:0;flex:1;">' +
                  '<div style="display:flex;align-items:baseline;gap:6px;">' +
                    '<span style="font-size:23px;font-weight:800;line-height:1.05;letter-spacing:-0.01em;' + NUM + '">{{ distText }}</span>' +
                    '<span ng-if="nav.isHighwayExit" style="font-size:10px;font-weight:800;letter-spacing:0.06em;text-transform:uppercase;padding:1px 5px;border-radius:3px;background:rgba(255,255,255,0.22);">EXIT</span>' +
                    '<span ng-if="nav.exitNum && !nav.isHighwayExit" style="font-size:10px;font-weight:800;letter-spacing:0.04em;text-transform:uppercase;padding:1px 5px;border-radius:3px;background:rgba(255,255,255,0.22);">EXIT {{ nav.exitNum }}</span>' +
                  '</div>' +
                  '<div style="font-size:13.5px;font-weight:700;line-height:1.25;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ primaryTitle }}</div>' +
                '</div>' +
              '</div>' +
              CTRL_BAR +
            '</div>' +
            '<div style="position:absolute;left:0;right:0;bottom:0;height:3px;background:rgba(0,0,0,0.28);">' +
              '<div ng-style="{width: progressPct + \'%\'}" style="height:100%;background:var(--bng-orange-b400,#ff6600);"></div>' +
            '</div>' +
          '</div>' +

          // ACTIVE ROUTE: Compact "Then:" sub-bar
          '<div ng-if="nav.active && nav.nextManeuver" ng-style="subBannerStyle" ' +
            'style="display:flex;align-items:center;gap:6px;padding:5px 11px;color:rgba(255,255,255,0.92);font-size:11.5px;font-weight:600;border-top:1px solid rgba(255,255,255,0.12);">' +
            '<span style="opacity:0.78;text-transform:uppercase;font-size:10px;letter-spacing:0.05em;">Then</span>' +
            svgPaths('nav.nextManeuver', 15) +
            '<span style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ nav.nextStreetName || nextActionLabel }}</span>' +
          '</div>' +

          // ACTIVE ROUTE: Spacious bottom trip footer with 36px crisp SVG speed sign
          '<div ng-if="nav.active" style="display:flex;align-items:center;justify-content:space-between;gap:10px;padding:8px 12px;background:' + CARD_BG + ';color:var(--bng-off-white,#f0f0f0);font-size:12.5px;">' +
            '<div style="display:flex;align-items:center;gap:7px;min-width:0;flex-wrap:wrap;' + NUM + '">' +
              '<span style="font-weight:800;color:var(--bng-orange-b400,#ff6600);">{{ etaText }}</span>' +
              '<span style="opacity:0.4;">&middot;</span>' +
              '<span style="font-weight:700;">{{ remText }}</span>' +
              '<span style="opacity:0.4;">&middot;</span>' +
              '<span style="color:var(--bng-cool-gray-300,#b4b8c2);">{{ arrivalClock }}</span>' +
            '</div>' +
            speedSignSvg(36) +
          '</div>' +

          // IDLE CRUISE STATE (Always visible)
          '<div ng-if="!nav.active" style="padding:10px 12px;background:' + CARD_BG + ';color:var(--bng-off-white,#f0f0f0);">' +
            '<div style="display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:7px;">' +
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
                '<div style="font-size:13.5px;font-weight:700;line-height:1.25;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ cruiseTitle }}</div>' +
                '<div style="font-size:11px;color:var(--bng-cool-gray-300,#b4b8c2);margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ cruiseSub }}</div>' +
              '</div>' +
              speedSignSvg(36) +
            '</div>' +
          '</div>' +
        '</div>' +

        // ============================================================
        // DESIGN 2: round_minimap (Pure Vector <svg>, 1:1 Minimap Palette, ResizeObserver + minimapSize)
        // ============================================================
        '<div ng-if="nav && nav.enabled && !hidden && nav.navDesign === \'round_minimap\'" ' +
          'style="display:flex;flex-direction:column;align-items:center;width:100%;margin:0 auto;overflow:visible;">' +

          // Compact top control strip (24px) — outside circle, always clickable
          '<div ng-style="{width: headerWidth + \'px\'}" style="display:flex;align-items:center;justify-content:space-between;gap:6px;margin-bottom:4px;">' +
            '<div style="padding:2px 7px;border-radius:var(--bng-corners-1,4px);background:rgba(8,10,14,0.76);border:1px solid rgba(255,255,255,0.12);color:#e4e8ef;font-size:10px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1;min-width:0;' + NUM + '">' +
              '{{ nav.active ? (nav.isHighwayExit ? "AUTOBAHN EXIT" : "NAVIGATION") : (cardinalText + " " + headingText + " · " + speedText) }}' +
            '</div>' +
            CTRL_BAR +
          '</div>' +

          // Docked compact turn-by-turn banner (52px, only when active)
          '<div ng-if="nav.active" ng-style="dockBannerStyle" ' +
            'style="position:relative;border-radius:var(--bng-corners-2,7px);padding:5px 9px 7px;color:#ffffff;border:1px solid rgba(255,255,255,0.16);margin-bottom:5px;overflow:hidden;box-sizing:border-box;">' +
            '<div style="display:flex;align-items:center;gap:8px;">' +
              svgPaths('nav.maneuver', 22) +
              '<div style="min-width:0;flex:1;">' +
                '<div style="display:flex;align-items:baseline;justify-content:space-between;gap:5px;">' +
                  '<span style="font-size:15.5px;font-weight:800;line-height:1.05;' + NUM + '">{{ distText }}</span>' +
                  '<span style="font-size:10px;font-weight:700;opacity:0.9;' + NUM + '">{{ etaText }}</span>' +
                '</div>' +
                '<div style="font-size:11.5px;font-weight:700;line-height:1.2;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:1px;">{{ primaryTitle }}</div>' +
              '</div>' +
            '</div>' +
            '<div style="position:absolute;left:0;right:0;bottom:0;height:2.5px;background:rgba(0,0,0,0.28);">' +
              '<div ng-style="{width: progressPct + \'%\'}" style="height:100%;background:var(--bng-orange-b400,#ff6600);"></div>' +
            '</div>' +
          '</div>' +

          // Pure Vector <svg> circular minimap (scales dynamically from 160px..360px, default 236px)
          '<div ng-style="{width: mapDiameter + \'px\', height: mapDiameter + \'px\'}" ' +
            'style="position:relative;overflow:visible;flex-shrink:0;">' +
            '<svg class="bng-nav-minimap-svg" viewBox="0 0 200 200" ' +
              'ng-attr-width="{{ mapDiameter }}" ng-attr-height="{{ mapDiameter }}" ' +
              'style="display:block;overflow:visible;">' +
              '<defs>' +
                '<clipPath id="bngNavCircleClip"><circle cx="100" cy="100" r="98.5"/></clipPath>' +
              '</defs>' +
              // Deep translucent black glass circle + ultra-subtle hairline border (exact native minimap look)
              '<circle cx="100" cy="100" r="98.5" fill="rgba(8,10,14,0.52)" stroke="rgba(255,255,255,0.08)" stroke-width="1"/>' +
              // Clipped vector map group
              '<g clip-path="url(#bngNavCircleClip)">' +
                '<g class="bng-nav-world" transform="translate(100,108)">' +
                  // Road casings by class (world-space paths, non-scaling-stroke)
                  '<path class="bng-nav-rc3" fill="none" stroke="rgba(0,0,0,0.68)" stroke-width="4.8" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke" d=""/>' +
                  '<path class="bng-nav-rc2" fill="none" stroke="rgba(0,0,0,0.72)" stroke-width="5.2" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke" d=""/>' +
                  '<path class="bng-nav-rc1" fill="none" stroke="rgba(0,0,0,0.76)" stroke-width="5.8" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke" d=""/>' +
                  '<path class="bng-nav-rc0" fill="none" stroke="rgba(0,0,0,0.80)" stroke-width="6.8" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke" d=""/>' +
                  // Distinct road-class fills: crisp off-white primary/highway, warm sand/taupe minor/service roads
                  '<path class="bng-nav-rf3" fill="none" stroke="#8e8878" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke" d=""/>' +
                  '<path class="bng-nav-rf2" fill="none" stroke="#a8a292" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke" d=""/>' +
                  '<path class="bng-nav-rf1" fill="none" stroke="#e4e6eb" stroke-width="3.8" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke" d=""/>' +
                  '<path class="bng-nav-rf0" fill="none" stroke="#e4e6eb" stroke-width="4.6" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke" d=""/>' +
                  // Exact royal blue route (#1664f6, 4.2px) over crisp white casing (#ffffff, 6.2px)
                  '<path class="bng-nav-route-bg" fill="none" stroke="#ffffff" stroke-width="6.2" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke" d=""/>' +
                  '<path class="bng-nav-route-fg" fill="none" stroke="#1664f6" stroke-width="4.2" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke" d=""/>' +
                '</g>' +
                // Sleek rounded orange-with-white-border player chevron (rotated by vehHeading - camHeading)
                '<g class="bng-nav-arrow" transform="translate(100,108) rotate(0)">' +
                  '<path d="M 0,-11 Q 2.4,-5.2 7.8,6.2 Q 8.4,8.2 6.3,7.3 Q 1.7,4.6 0,4.4 Q -1.7,4.6 -6.3,7.3 Q -8.4,8.2 -7.8,6.2 Q -2.4,-5.2 0,-11 Z" ' +
                    'fill="#ff6600" stroke="#ffffff" stroke-width="2.1" stroke-linejoin="round"/>' +
                '</g>' +
                // North compass marker on inner rim (moves with camera rotation)
                '<g class="bng-nav-north" transform="translate(100,14)">' +
                  '<circle cx="0" cy="0" r="8.5" fill="rgba(8,10,14,0.78)"/>' +
                  '<text x="0" y="0.6" text-anchor="middle" dominant-baseline="central" fill="#ff6600" ' +
                    'font-family="Overpass, sans-serif" font-size="10" font-weight="800">N</text>' +
                '</g>' +
              '</g>' +
            '</svg>' +

            // Crisp vector 32px speed-limit badge tucked cleanly at bottom-left rim (never clipped)
            '<div ng-if="limitBadgeText" style="position:absolute;bottom:6px;left:2px;z-index:4;">' +
              speedSignSvg(32) +
            '</div>' +

            // Bottom distance / street pill overlapping lower rim inside bounding box (bottom: 4px)
            '<div style="position:absolute;left:0;right:0;bottom:4px;display:flex;justify-content:center;pointer-events:none;z-index:4;">' +
              '<div style="max-width:74%;padding:2px 9px;border-radius:10px;background:rgba(8,10,14,0.84);border:1px solid rgba(255,255,255,0.14);color:#f4f6f8;font-size:10.5px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;' + NUM + '">' +
                '{{ nav.active ? (remText + " · " + etaText) : cruiseTitle }}' +
              '</div>' +
            '</div>' +
          '</div>' +
        '</div>' +

        // ============================================================
        // DESIGN 3: ets_advisor (ETS2 / Truck Cockpit Route Advisor — Always Visible, Zero Shadow)
        // ============================================================
        '<div ng-if="nav && nav.enabled && !hidden && nav.navDesign === \'ets_advisor\'" ' +
          'style="width:100%;background:' + CARD_BG + ';color:var(--bng-off-white,#f0f0f0);border-radius:var(--bng-corners-1,4px);border:1px solid rgba(255,255,255,0.16);overflow:hidden;">' +
          '<div style="display:flex;align-items:center;justify-content:space-between;gap:6px;padding:4px 9px;background:rgba(0,0,0,0.34);border-bottom:1px solid rgba(255,255,255,0.1);font-size:10.5px;">' +
            '<div style="display:flex;align-items:center;gap:5px;min-width:0;' + NUM + '">' +
              '<span style="color:var(--bng-orange-b400,#ff6600);font-weight:800;letter-spacing:0.05em;">{{ cardinalText }}</span>' +
              '<span style="color:var(--bng-cool-gray-300,#b4b8c2);">{{ headingText }}</span>' +
              '<span style="opacity:0.35;">|</span>' +
              '<span style="max-width:118px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:var(--bng-cool-gray-200,#d4d8e0);">{{ cruiseTitle }}</span>' +
            '</div>' +
            CTRL_BAR +
          '</div>' +

          '<div style="display:flex;align-items:center;gap:9px;padding:8px 10px;">' +
            '<svg width="36" height="36" viewBox="0 0 36 36" style="display:block;flex-shrink:0;">' +
              '<circle cx="18" cy="18" r="16" ng-attr-fill="{{ limitSvgFill }}" ng-attr-stroke="{{ limitSvgStroke }}" stroke-width="3.2"/>' +
              '<text x="18" y="18.6" text-anchor="middle" dominant-baseline="central" ng-attr-fill="{{ limitSvgText }}" ' +
                'font-family="Overpass, sans-serif" font-size="13.5" font-weight="800">{{ limitBadgeText || "--" }}</text>' +
            '</svg>' +

            '<div style="display:flex;align-items:center;gap:8px;flex:1;min-width:0;">' +
              '<div ng-if="nav.active" ng-style="bannerStyle" style="width:34px;height:34px;border-radius:var(--bng-corners-1,4px);display:flex;align-items:center;justify-content:center;color:#fff;flex-shrink:0;">' +
                svgPaths('nav.maneuver', 22) +
              '</div>' +
              '<div style="min-width:0;flex:1;">' +
                '<div ng-if="nav.active" style="display:flex;align-items:baseline;gap:5px;">' +
                  '<span style="font-size:17px;font-weight:800;line-height:1.05;' + NUM + '">{{ distText }}</span>' +
                  '<span ng-if="nav.isHighwayExit" style="font-size:9px;font-weight:800;padding:1px 4px;border-radius:2px;background:#0b4f8c;color:#fff;letter-spacing:0.05em;">EXIT</span>' +
                '</div>' +
                '<div ng-if="!nav.active" style="font-size:11px;font-weight:700;color:var(--bng-cool-gray-300,#b4b8c2);">Cruise · Free Drive</div>' +
                '<div style="font-size:12px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:#f4f6f8;">{{ nav.active ? primaryTitle : cruiseSub }}</div>' +
                '<div ng-if="nav.active" style="height:2.5px;background:rgba(255,255,255,0.14);border-radius:2px;margin-top:4px;overflow:hidden;">' +
                  '<div ng-style="{width: progressPct + \'%\'}" style="height:100%;background:var(--bng-orange-b400,#ff6600);"></div>' +
                '</div>' +
              '</div>' +
            '</div>' +

            '<div style="text-align:right;flex-shrink:0;padding-left:8px;border-left:1px solid rgba(255,255,255,0.12);' + NUM + '">' +
              '<div style="font-size:13px;font-weight:800;color:var(--bng-orange-b400,#ff6600);">{{ nav.active ? etaText : speedText }}</div>' +
              '<div style="font-size:10.5px;font-weight:600;color:var(--bng-cool-gray-300,#b4b8c2);">{{ nav.active ? remText : "CRUISE" }}</div>' +
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
      scope.mapDiameter = 236
      scope.headerWidth = 236
      scope.limitBadgeText = ''
      scope.limitSvgFill = '#262b33'
      scope.limitSvgStroke = '#48515e'
      scope.limitSvgText = '#9aa2b0'
      scope.bannerStyle = { background: '#14532d' }
      scope.dockBannerStyle = { background: '#14532d', width: '236px' }
      scope.subBannerStyle = { background: '#0e3c20' }

      var lastChimeSeq = -1
      var audioCtx = null

      // ResizeObserver state for UI Apps editor drag-resizing (160px..360px)
      var boxW = 0
      var boxH = 0
      var resizeObs = null

      // High-FPS pose & smooth interpolation state for 60-FPS requestAnimationFrame loop
      var poseInitialized = false
      var targetPose = { x: 0, y: 0, vehHeadingRad: 0, camHeadingRad: 0, speedKph: 0 }
      var renderPose = { x: 0, y: 0, vehHeadingRad: 0, camHeadingRad: 0, speedKph: 0 }
      var rafId = null
      var lastRafMs = 0
      var lastHudTextPoseMs = 0
      var lastAppliedRoadsSeq = -1
      var latestRoads = null
      var latestRoadsSeq = -1
      var prevDesign = ''
      var svgRefs = null

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

      function ensureSvgRefs () {
        if (svgRefs && svgRefs.svg && svgRefs.svg.isConnected) return svgRefs
        var el = element && element[0]
        if (!el) return null
        var svg = el.querySelector('.bng-nav-minimap-svg')
        if (!svg) return null
        svgRefs = {
          svg: svg,
          world: svg.querySelector('.bng-nav-world'),
          arrow: svg.querySelector('.bng-nav-arrow'),
          north: svg.querySelector('.bng-nav-north'),
          rc: [
            svg.querySelector('.bng-nav-rc0'),
            svg.querySelector('.bng-nav-rc1'),
            svg.querySelector('.bng-nav-rc2'),
            svg.querySelector('.bng-nav-rc3')
          ],
          rf: [
            svg.querySelector('.bng-nav-rf0'),
            svg.querySelector('.bng-nav-rf1'),
            svg.querySelector('.bng-nav-rf2'),
            svg.querySelector('.bng-nav-rf3')
          ],
          routeBg: svg.querySelector('.bng-nav-route-bg'),
          routeFg: svg.querySelector('.bng-nav-route-fg')
        }
        lastAppliedRoadsSeq = -1
        return svgRefs
      }

      // Rebuild world-space vector road <path> geometry immediately on road feed updates
      function rebuildRoadPaths (refs, roads) {
        var buckets = [[], [], [], []]
        if (Array.isArray(roads) && roads.length >= 5) {
          for (var i = 0; i < roads.length; i += 5) {
            var cls = roads[i + 4]
            var b = cls === 0 ? 0 : (cls === 1 ? 1 : (cls === 2 ? 2 : 3))
            // World ENU (x East, y North) -> SVG (x, -y) so +Y North points UP
            buckets[b].push('M' + roads[i] + ',' + (-roads[i + 1]) + 'L' + roads[i + 2] + ',' + (-roads[i + 3]))
          }
        }
        for (var c = 0; c < 4; c++) {
          var d = buckets[c].join('')
          if (refs.rc[c]) refs.rc[c].setAttribute('d', d)
          if (refs.rf[c]) refs.rf[c].setAttribute('d', d)
        }
      }

      function applyRoadSnapshot (seq, roads) {
        if (Array.isArray(roads)) {
          latestRoads = roads
          latestRoadsSeq = Number(seq) || (latestRoadsSeq + 1)
          var refs = ensureSvgRefs()
          if (refs) {
            lastAppliedRoadsSeq = latestRoadsSeq
            rebuildRoadPaths(refs, latestRoads)
          }
        }
      }

      function fetchRoadsNow () {
        bngApi.engineLua('if beamngEarth_turnByTurn and beamngEarth_turnByTurn.getRoads then return beamngEarth_turnByTurn.getRoads() end', function (res) {
          if (res && Array.isArray(res.roads)) {
            applyRoadSnapshot(res.seq, res.roads)
          }
        })
      }

      // 60-FPS Pure Vector SVG update (exact camera-pan rotation, relative chevron, zero-lag route)
      function updateRoundMinimapSvg () {
        var nav = scope.nav
        if (!nav || !nav.enabled || scope.hidden || nav.navDesign !== 'round_minimap') return
        var refs = ensureSvgRefs()
        if (!refs || !refs.world) return

        if (latestRoads && lastAppliedRoadsSeq !== latestRoadsSeq) {
          lastAppliedRoadsSeq = latestRoadsSeq
          rebuildRoadPaths(refs, latestRoads)
        }

        var cx = 100
        var cy = 108
        var spd = renderPose.speedKph
        var viewM = Math.max(155, Math.min(380, 155 + spd * 1.7))
        var pxPerM = 92 / viewM
        var px = renderPose.x
        var py = renderPose.y

        // Camera yaw (clockwise from North): rotate SVG world group COUNTER-CLOCKWISE (-camDeg)
        // so camera look direction always points straight UP (-Y in SVG).
        var camRad = nav.northUp ? 0 : renderPose.camHeadingRad
        var camDeg = (camRad * 180) / Math.PI
        var vehDeg = (renderPose.vehHeadingRad * 180) / Math.PI
        var arrowDeg = nav.northUp ? vehDeg : (vehDeg - camDeg)

        refs.world.setAttribute(
          'transform',
          'translate(' + cx + ',' + cy + ') rotate(' + (-camDeg).toFixed(2) + ') scale(' + pxPerM.toFixed(5) + ') translate(' + (-px).toFixed(2) + ',' + py.toFixed(2) + ')'
        )

        if (refs.arrow) {
          refs.arrow.setAttribute('transform', 'translate(' + cx + ',' + cy + ') rotate(' + arrowDeg.toFixed(2) + ')')
        }

        // North marker moves counter-clockwise around rim by -camRad (when facing East +90 deg, N is on LEFT)
        if (refs.north) {
          var nx = 100 - Math.sin(camRad) * 84
          var ny = 100 - Math.cos(camRad) * 84
          refs.north.setAttribute('transform', 'translate(' + nx.toFixed(2) + ',' + ny.toFixed(2) + ')')
        }

        // Zero-lag route path: project (px, py) onto closest route segment and trim passed vertices
        var rpts = nav.miniRoute
        if (refs.routeBg && refs.routeFg) {
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
            var startX = bestDistSq <= 196 ? px : projX
            var startY = bestDistSq <= 196 ? py : projY
            var segs = ['M' + startX.toFixed(2) + ',' + (-startY).toFixed(2)]
            for (var k = bestSeg + 2; k < rpts.length; k += 2) {
              segs.push('L' + rpts[k] + ',' + (-rpts[k + 1]))
            }
            var rd = segs.join('')
            refs.routeBg.setAttribute('d', rd)
            refs.routeFg.setAttribute('d', rd)
          } else {
            refs.routeBg.setAttribute('d', '')
            refs.routeFg.setAttribute('d', '')
          }
        }
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

        updateRoundMinimapSvg()
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

      function recomputeMapSize () {
        var nav = scope.nav
        var pref = Math.max(180, Math.min(320, Math.round(Number(nav && nav.minimapSize) || 236)))
        var overhead = (nav && nav.active) ? 86 : 30
        var diam = pref
        if (boxW > 80 && boxH > 80) {
          var avail = Math.floor(Math.min(boxW - 6, boxH - overhead))
          if (avail > pref + 12) {
            // Dragged larger in UI Apps editor: scale smoothly up to 360px
            diam = Math.min(360, avail)
          } else if (avail < pref) {
            // Container is smaller than preference: fit cleanly without clipping
            diam = Math.max(160, avail)
          }
        }
        scope.mapDiameter = Math.max(160, Math.min(360, diam))
        scope.headerWidth = Math.max(216, Math.min(340, scope.mapDiameter))
        var bg = (nav && nav.isHighwayExit) ? '#0b4f8c' : '#14532d'
        scope.dockBannerStyle = { background: bg, width: scope.headerWidth + 'px' }
      }

      function applyNav (nav) {
        scope.nav = nav || null
        if (!nav) {
          syncRafLoop()
          return
        }

        var design = nav.navDesign || 'gmaps_card'
        scope.designBadge = design === 'gmaps_card' ? '1/3' : (design === 'round_minimap' ? '2/3' : '3/3')
        if (design === 'round_minimap' && prevDesign !== 'round_minimap') {
          fetchRoadsNow()
        }
        prevDesign = design

        if (nav.isHighwayExit) {
          scope.bannerStyle = { background: '#0b4f8c' }
          scope.subBannerStyle = { background: '#073966' }
        } else {
          scope.bannerStyle = { background: '#14532d' }
          scope.subBannerStyle = { background: '#0d3b20' }
        }
        recomputeMapSize()

        scope.distText = formatDist(nav.distToTurnM, nav.units)
        scope.remText = formatDist(nav.remainingM, nav.units)
        scope.etaText = formatEta(nav.etaSec)
        scope.arrivalClock = formatArrival(nav.etaSec)
        scope.progressPct = Math.max(0, Math.min(100, Math.round((Number(nav.approachProgress) || 0) * 100)))

        var fallbackAction = ACTION_LABELS[nav.maneuver] || 'Continue'
        scope.primaryTitle = nav.streetName || nav.destName || fallbackAction
        scope.nextActionLabel = ACTION_LABELS[nav.nextManeuver] || ''

        scope.cruiseTitle = nav.currentStreet || nav.currentPlace || nav.coordsLabel || 'Free Drive'
        if (nav.currentStreet && nav.currentPlace) {
          scope.cruiseSub = nav.currentPlace
        } else if (nav.coordsLabel) {
          scope.cruiseSub = nav.coordsLabel
        } else {
          scope.cruiseSub = 'Set a destination on Map'
        }

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

        // Crisp SVG speed-limit colors
        if (nav.speedLimitUnlimited) {
          scope.limitBadgeText = '///'
          scope.limitSvgFill = '#e5e7eb'
          scope.limitSvgStroke = '#4b5563'
          scope.limitSvgText = '#374151'
        } else if (nav.speedLimitKph != null && nav.speedLimitKph > 0) {
          var dispLim = nav.units === 'imperial'
            ? Math.round(nav.speedLimitKph * 0.621371)
            : Math.round(nav.speedLimitKph)
          scope.limitBadgeText = String(dispLim)
          scope.limitSvgFill = '#ffffff'
          scope.limitSvgStroke = '#d92d20'
          scope.limitSvgText = '#111827'
        } else {
          scope.limitBadgeText = ''
          scope.limitSvgFill = '#262b33'
          scope.limitSvgStroke = '#48515e'
          scope.limitSvgText = '#9aa2b0'
        }

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
      if (typeof window.ResizeObserver === 'function' && element && element[0]) {
        try {
          resizeObs = new window.ResizeObserver(function (entries) {
            if (!entries || !entries.length) return
            var cr = entries[0].contentRect
            if (!cr) return
            var nw = Math.round(cr.width)
            var nh = Math.round(cr.height)
            if (nw !== boxW || nh !== boxH) {
              boxW = nw
              boxH = nh
              scope.$evalAsync(function () { recomputeMapSize() })
            }
          })
          resizeObs.observe(element[0])
        } catch (e) {}
      }
      bngApi.engineLua('if beamngEarth_core then beamngEarth_core.hudApp("nav", true) end')
      bngApi.engineLua('if beamngEarth_turnByTurn and beamngEarth_turnByTurn.uiState then return beamngEarth_turnByTurn.uiState() end', function (st) {
        if (st && typeof st === 'object') {
          scope.$evalAsync(function () { applyNav(st) })
        }
      })
      fetchRoadsNow()

      // Instant full-coverage road geometry push from Lua (0-frame lag on new tiles or > 35 m movement)
      scope.$on('BeamNGEarthNavRoads', function (_, msg) {
        if (!msg || !Array.isArray(msg.roads)) return
        applyRoadSnapshot(msg.seq, msg.roads)
      })

      scope.$on('BeamNGEarthHud', function (_, data) {
        if (!data) return
        scope.$evalAsync(function () {
          scope.hidden = !!data.hidden
          applyNav(data.nav)
        })
      })

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
        var now = Date.now()
        if (scope.nav && (now - lastHudTextPoseMs) >= 80) {
          lastHudTextPoseMs = now
          scope.$evalAsync(function () {
            formatHeadingFields(pose.headingDeg, pose.speedKph, scope.nav && scope.nav.units)
          })
        }
      })

      scope.$on('$destroy', function () {
        if (resizeObs) {
          try { resizeObs.disconnect() } catch (e) {}
          resizeObs = null
        }
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
