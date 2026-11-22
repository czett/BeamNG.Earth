// BeamNG.Earth Turn-by-Turn Navigation & Multi-Design HUD App (turnByTurn.lua + hudapps.lua).
// 3 switchable designs: 'gmaps_card' (Google Maps/CarPlay card), 'round_minimap' (circular minimap + turn header),
// and 'ets_advisor' (wide cockpit route advisor). Styled with native BeamNG HUD tokens and Overpass typography.
angular.module('beamng.apps')
.directive('beamngEarthNav', [function () {
  var FONT = 'font-family:"Overpass",var(--fnt-defs,sans-serif);'
  var NUM = 'font-variant-numeric:tabular-nums;'
  var CARD_BG = 'rgba(var(--bng-off-black-rgb,26,26,26),0.86)'
  var CTRL_BTN = 'background:rgba(15,18,24,0.72);color:var(--bng-off-white,#f0f0f0);' +
    'border:1px solid rgba(255,255,255,0.22);border-radius:var(--bng-corners-1,4px);' +
    'padding:2px 6px;font-size:10px;font-weight:700;cursor:pointer;line-height:1.2;' +
    'display:inline-flex;align-items:center;justify-content:center;gap:3px;' + FONT + NUM

  function svgPaths (varName, size) {
    return '<svg width="' + size + '" height="' + size + '" viewBox="0 0 24 24" fill="none" ' +
      'stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" ' +
      'style="display:block;flex-shrink:0;" ng-switch="' + varName + '">' +
      // turn_left
      '<g ng-switch-when="turn_left"><path d="M16 20V11a3 3 0 0 0-3-3H6"/><polyline points="10 4 6 8 10 12"/></g>' +
      // turn_right
      '<g ng-switch-when="turn_right"><path d="M8 20V11a3 3 0 0 1 3-3h7"/><polyline points="14 4 18 8 14 12"/></g>' +
      // slight_left
      '<g ng-switch-when="slight_left"><path d="M15 20v-5.5a3 3 0 0 0-.88-2.12L8 6"/><polyline points="13 6 8 6 8 11"/></g>' +
      // slight_right
      '<g ng-switch-when="slight_right"><path d="M9 20v-5.5a3 3 0 0 1 .88-2.12L16 6"/><polyline points="11 6 16 6 16 11"/></g>' +
      // sharp_left
      '<g ng-switch-when="sharp_left"><path d="M17 20V7a2 2 0 0 0-3.41-1.41L6 13.5"/><polyline points="6 8.5 6 13.5 11 13.5"/></g>' +
      // sharp_right
      '<g ng-switch-when="sharp_right"><path d="M7 20V7a2 2 0 0 1 3.41-1.41L18 13.5"/><polyline points="18 8.5 18 13.5 13 13.5"/></g>' +
      // uturn
      '<g ng-switch-when="uturn"><path d="M16 20V9a4 4 0 0 0-8 0v8"/><polyline points="4 13 8 17 12 13"/></g>' +
      // exit_right (highway main stem + right exit ramp)
      '<g ng-switch-when="exit_right">' +
        '<path d="M8 20V5" opacity="0.45"/>' +
        '<path d="M8 15c0-3 2-5 6-7.5L18 5"/>' +
        '<polyline points="13.5 4.5 18 5 17.5 9.5"/>' +
      '</g>' +
      // exit_left
      '<g ng-switch-when="exit_left">' +
        '<path d="M16 20V5" opacity="0.45"/>' +
        '<path d="M16 15c0-3-2-5-6-7.5L6 5"/>' +
        '<polyline points="10.5 4.5 6 5 6.5 9.5"/>' +
      '</g>' +
      // merge_left
      '<g ng-switch-when="merge_left">' +
        '<path d="M10 20V5"/><polyline points="6 9 10 5 14 9"/>' +
        '<path d="M18 19c-2-2-4-4-8-8"/>' +
      '</g>' +
      // merge_right
      '<g ng-switch-when="merge_right">' +
        '<path d="M14 20V5"/><polyline points="10 9 14 5 18 9"/>' +
        '<path d="M6 19c2-2 4-4 8-8"/>' +
      '</g>' +
      // roundabout
      '<g ng-switch-when="roundabout">' +
        '<circle cx="12" cy="11" r="4"/>' +
        '<path d="M12 20v-5"/><path d="M15 8.5L19 5"/><polyline points="15 5 19 5 19 9"/>' +
      '</g>' +
      // arrive (checkered/pin target)
      '<g ng-switch-when="arrive">' +
        '<path d="M12 21s-6-5.2-6-10a6 6 0 1 1 12 0c0 4.8-6 10-6 10z"/>' +
        '<circle cx="12" cy="11" r="2.2" fill="currentColor" stroke="none"/>' +
      '</g>' +
      // straight / default
      '<g ng-switch-default><path d="M12 20V5"/><polyline points="7 10 12 5 17 10"/></g>' +
    '</svg>'
  }

  var CTRL_BAR =
    '<div class="bng-nav-ctrls" ng-style="{opacity: hovering ? 1 : 0.45}" ' +
      'style="display:flex;align-items:center;gap:4px;transition:opacity 120ms ease;">' +
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
      '<div class="bngApp" ng-mouseenter="hovering=true" ng-mouseleave="hovering=false" ' +
        'style="width:100%;height:100%;background:transparent;box-shadow:none;overflow:visible;' + FONT + '">' +

        // ============================================================
        // DESIGN 1: gmaps_card (Google Maps / CarPlay Turn Card)
        // ============================================================
        '<div ng-if="nav && nav.enabled && nav.active && !hidden && nav.navDesign === \'gmaps_card\'" ' +
          'style="width:100%;border-radius:var(--bng-corners-2,8px);overflow:hidden;box-shadow:0 4px 16px rgba(0,0,0,0.45);border:1px solid rgba(255,255,255,0.12);">' +
          // Top high-contrast maneuver banner
          '<div ng-style="bannerStyle" style="position:relative;padding:10px 12px 11px;color:#ffffff;">' +
            '<div style="position:absolute;top:7px;right:8px;">' + CTRL_BAR + '</div>' +
            '<div style="display:flex;align-items:center;gap:11px;padding-right:64px;">' +
              '<div style="width:42px;height:42px;border-radius:var(--bng-corners-1,6px);background:rgba(0,0,0,0.22);display:flex;align-items:center;justify-content:center;flex-shrink:0;">' +
                svgPaths('nav.maneuver', 30) +
              '</div>' +
              '<div style="min-width:0;flex:1;">' +
                '<div style="display:flex;align-items:baseline;gap:6px;">' +
                  '<span style="font-size:24px;font-weight:800;line-height:1.05;letter-spacing:-0.01em;' + NUM + '">{{ distText }}</span>' +
                  '<span ng-if="nav.isHighwayExit" style="font-size:10px;font-weight:800;letter-spacing:0.06em;text-transform:uppercase;padding:1px 5px;border-radius:3px;background:rgba(255,255,255,0.2);">EXIT</span>' +
                  '<span ng-if="nav.exitNum && !nav.isHighwayExit" style="font-size:10px;font-weight:800;letter-spacing:0.04em;text-transform:uppercase;padding:1px 5px;border-radius:3px;background:rgba(255,255,255,0.2);">EXIT {{ nav.exitNum }}</span>' +
                '</div>' +
                '<div style="font-size:14px;font-weight:700;line-height:1.25;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ primaryTitle }}</div>' +
              '</div>' +
            '</div>' +
            // Live approach progress bar
            '<div style="position:absolute;left:0;right:0;bottom:0;height:3px;background:rgba(0,0,0,0.28);">' +
              '<div ng-style="{width: progressPct + \'%\'}" style="height:100%;background:var(--bng-orange-b400,#ff6600);transition:width 180ms linear;"></div>' +
            '</div>' +
          '</div>' +

          // Compact "Then:" sub-bar
          '<div ng-if="nav.nextManeuver" ng-style="subBannerStyle" ' +
            'style="display:flex;align-items:center;gap:6px;padding:5px 12px;color:rgba(255,255,255,0.92);font-size:11.5px;font-weight:600;border-top:1px solid rgba(255,255,255,0.12);">' +
            '<span style="opacity:0.78;text-transform:uppercase;font-size:10px;letter-spacing:0.05em;">Then</span>' +
            svgPaths('nav.nextManeuver', 15) +
            '<span style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ nav.nextStreetName || nextActionLabel }}</span>' +
          '</div>' +

          // Bottom trip footer
          '<div style="display:flex;align-items:center;justify-content:space-between;gap:8px;padding:6px 12px;background:' + CARD_BG + ';color:var(--bng-off-white,#f0f0f0);font-size:12px;">' +
            '<div style="display:flex;align-items:center;gap:8px;' + NUM + '">' +
              '<span style="font-weight:800;color:var(--bng-orange-b400,#ff6600);">{{ etaText }}</span>' +
              '<span style="opacity:0.4;">&middot;</span>' +
              '<span style="font-weight:700;">{{ remText }}</span>' +
              '<span style="opacity:0.4;">&middot;</span>' +
              '<span style="color:var(--bng-cool-gray-300,#b4b8c2);">{{ arrivalClock }}</span>' +
            '</div>' +
            '<div ng-if="limitBadgeText" style="width:22px;height:22px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:800;' + NUM + '" ng-style="limitBadgeStyle">{{ limitBadgeText }}</div>' +
          '</div>' +
        '</div>' +

        // ============================================================
        // DESIGN 2: round_minimap (Circular Minimap + Integrated Turn Header)
        // ============================================================
        '<div ng-if="nav && nav.enabled && !hidden && nav.navDesign === \'round_minimap\'" ' +
          'style="display:flex;flex-direction:column;align-items:center;width:228px;margin:0 auto;">' +
          // Docked compact turn-by-turn banner on top
          '<div ng-if="nav.active" ng-style="bannerStyle" ' +
            'style="position:relative;width:224px;border-radius:var(--bng-corners-2,8px);padding:6px 9px 8px;color:#ffffff;box-shadow:0 3px 12px rgba(0,0,0,0.45);border:1px solid rgba(255,255,255,0.16);margin-bottom:-10px;z-index:2;overflow:hidden;">' +
            '<div style="display:flex;align-items:center;gap:8px;">' +
              svgPaths('nav.maneuver', 22) +
              '<div style="min-width:0;flex:1;">' +
                '<div style="display:flex;align-items:baseline;justify-content:space-between;gap:4px;">' +
                  '<span style="font-size:16px;font-weight:800;line-height:1.05;' + NUM + '">{{ distText }}</span>' +
                  '<span style="font-size:10px;font-weight:700;opacity:0.86;' + NUM + '">{{ etaText }}</span>' +
                '</div>' +
                '<div style="font-size:11.5px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:1px;">{{ primaryTitle }}</div>' +
              '</div>' +
            '</div>' +
            '<div style="position:absolute;left:0;right:0;bottom:0;height:2.5px;background:rgba(0,0,0,0.3);">' +
              '<div ng-style="{width: progressPct + \'%\'}" style="height:100%;background:var(--bng-orange-b400,#ff6600);"></div>' +
            '</div>' +
          '</div>' +

          // Circular radar minimap body
          '<div style="position:relative;width:190px;height:190px;border-radius:50%;overflow:hidden;background:#161a21;border:2px solid rgba(255,255,255,0.2);box-shadow:0 6px 18px rgba(0,0,0,0.55);">' +
            '<canvas class="bng-nav-minimap-canvas" width="190" height="190" style="width:190px;height:190px;display:block;"></canvas>' +
            // Speed limit badge on top-left rim
            '<div ng-if="limitBadgeText" style="position:absolute;top:16px;left:16px;width:24px;height:24px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:800;box-shadow:0 1px 4px rgba(0,0,0,0.5);' + NUM + '" ng-style="limitBadgeStyle">{{ limitBadgeText }}</div>' +
            // Controls on top-right rim
            '<div style="position:absolute;top:14px;right:14px;">' + CTRL_BAR + '</div>' +
            // Bottom distance / coords pill
            '<div style="position:absolute;left:50%;bottom:8px;transform:translateX(-50%);max-width:152px;padding:2px 9px;border-radius:10px;background:rgba(15,18,24,0.86);border:1px solid rgba(255,255,255,0.16);color:#f0f0f0;font-size:10.5px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;' + NUM + '">' +
              '{{ nav.active ? (remText + " · " + etaText) : (nav.currentStreet || nav.coordsLabel || "GPS Ready") }}' +
            '</div>' +
          '</div>' +
        '</div>' +

        // ============================================================
        // DESIGN 3: ets_advisor (ETS2 / Truck Cockpit Route Advisor)
        // ============================================================
        '<div ng-if="nav && nav.enabled && !hidden && nav.navDesign === \'ets_advisor\'" ' +
          'style="width:100%;min-width:310px;background:' + CARD_BG + ';color:var(--bng-off-white,#f0f0f0);border-radius:var(--bng-corners-1,4px);border:1px solid rgba(255,255,255,0.14);box-shadow:0 4px 14px rgba(0,0,0,0.48);overflow:hidden;">' +
          // Top compass / heading strip
          '<div style="display:flex;align-items:center;justify-content:space-between;gap:8px;padding:4px 10px;background:rgba(0,0,0,0.34);border-bottom:1px solid rgba(255,255,255,0.09);font-size:10.5px;">' +
            '<div style="display:flex;align-items:center;gap:6px;' + NUM + '">' +
              '<span style="color:var(--bng-orange-b400,#ff6600);font-weight:800;letter-spacing:0.05em;">{{ cardinalText }}</span>' +
              '<span style="color:var(--bng-cool-gray-300,#b4b8c2);">{{ headingText }}</span>' +
              '<span style="opacity:0.35;">|</span>' +
              '<span style="max-width:130px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:var(--bng-cool-gray-200,#d0d4dc);">{{ nav.currentStreet || nav.coordsLabel || "Free Drive" }}</span>' +
            '</div>' +
            CTRL_BAR +
          '</div>' +

          // Main advisor telemetry row
          '<div style="display:flex;align-items:center;gap:10px;padding:8px 10px;">' +
            // Speed limit circular sign
            '<div style="width:36px;height:36px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:800;flex-shrink:0;' + NUM + '" ng-style="limitBadgeStyle">{{ limitBadgeText || "--" }}</div>' +

            // Next maneuver + street name
            '<div style="display:flex;align-items:center;gap:8px;flex:1;min-width:0;">' +
              '<div ng-if="nav.active" ng-style="bannerStyle" style="width:34px;height:34px;border-radius:var(--bng-corners-1,4px);display:flex;align-items:center;justify-content:center;color:#fff;flex-shrink:0;">' +
                svgPaths('nav.maneuver', 22) +
              '</div>' +
              '<div style="min-width:0;flex:1;">' +
                '<div ng-if="nav.active" style="display:flex;align-items:baseline;gap:6px;">' +
                  '<span style="font-size:17px;font-weight:800;line-height:1.05;' + NUM + '">{{ distText }}</span>' +
                  '<span ng-if="nav.isHighwayExit" style="font-size:9.5px;font-weight:800;padding:1px 4px;border-radius:2px;background:#0b4f8c;color:#fff;letter-spacing:0.05em;">EXIT</span>' +
                '</div>' +
                '<div ng-if="!nav.active" style="font-size:12px;font-weight:700;color:var(--bng-cool-gray-300,#b4b8c2);">Route Advisor Ready</div>' +
                '<div style="font-size:12px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:#f4f6f8;">{{ nav.active ? primaryTitle : (nav.currentStreet || "Set a destination on Map") }}</div>' +
                '<div ng-if="nav.active" style="height:2.5px;background:rgba(255,255,255,0.14);border-radius:2px;margin-top:4px;overflow:hidden;">' +
                  '<div ng-style="{width: progressPct + \'%\'}" style="height:100%;background:var(--bng-orange-b400,#ff6600);"></div>' +
                '</div>' +
              '</div>' +
            '</div>' +

            // Right remaining distance / ETA column
            '<div style="text-align:right;flex-shrink:0;padding-left:8px;border-left:1px solid rgba(255,255,255,0.1);' + NUM + '">' +
              '<div style="font-size:13px;font-weight:800;color:var(--bng-orange-b400,#ff6600);">{{ nav.active ? etaText : (speedText) }}</div>' +
              '<div style="font-size:11px;font-weight:600;color:var(--bng-cool-gray-300,#b4b8c2);">{{ nav.active ? remText : "LIVE" }}</div>' +
            '</div>' +
          '</div>' +
        '</div>' +

      '</div>',
    replace: true,
    link: function (scope, element) {
      'use strict'
      scope.nav = null
      scope.hidden = false
      scope.hovering = false
      scope.distText = '--'
      scope.remText = '--'
      scope.etaText = '--'
      scope.arrivalClock = '--:--'
      scope.primaryTitle = ''
      scope.nextActionLabel = ''
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

      // 2D Canvas renderer for 'round_minimap' design
      function drawRoundMinimap (nav) {
        var el = element && element[0]
        if (!el) return
        var canvas = el.querySelector('.bng-nav-minimap-canvas')
        if (!canvas || !canvas.getContext) return
        var ctx = canvas.getContext('2d')
        var w = canvas.width
        var h = canvas.height
        var cx = w * 0.5
        var cy = h * 0.54
        var radius = w * 0.49
        // Zoom scales gently with speed (urban ~180 m, highway ~360 m)
        var spd = Number(nav.speedKph) || 0
        var viewM = Math.max(160, Math.min(360, 160 + spd * 1.6))
        var pxPerM = (w * 0.46) / viewM
        var hdgRad = ((Number(nav.headingDeg) || 0) * Math.PI) / 180
        var rot = nav.northUp ? 0 : -hdgRad

        ctx.clearRect(0, 0, w, h)
        ctx.save()
        ctx.beginPath()
        ctx.arc(w * 0.5, h * 0.5, radius, 0, Math.PI * 2)
        ctx.clip()

        // Background
        ctx.fillStyle = '#171c24'
        ctx.fillRect(0, 0, w, h)

        // Subtle range ring
        ctx.strokeStyle = 'rgba(255,255,255,0.06)'
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.arc(cx, cy, w * 0.25, 0, Math.PI * 2)
        ctx.stroke()

        // Transform world ENU relative (dx East, dy North) -> canvas (x right, y down)
        function toScreen (dx, dy) {
          var rx = dx * Math.cos(rot) - dy * Math.sin(rot)
          var ry = dx * Math.sin(rot) + dy * Math.cos(rot)
          return [cx + rx * pxPerM, cy - ry * pxPerM]
        }

        // Nearby road segments
        var roads = nav.miniRoads
        if (Array.isArray(roads) && roads.length) {
          ctx.lineCap = 'round'
          for (var i = 0; i < roads.length; i++) {
            var seg = roads[i]
            var p1 = toScreen(seg[0], seg[1])
            var p2 = toScreen(seg[2], seg[3])
            var cls = seg[4] || 1
            ctx.strokeStyle = cls === 1 ? 'rgba(195,204,218,0.42)' : (cls === 2 ? 'rgba(155,165,180,0.28)' : 'rgba(120,130,145,0.18)')
            ctx.lineWidth = cls === 1 ? 3.2 : (cls === 2 ? 2.0 : 1.3)
            ctx.beginPath()
            ctx.moveTo(p1[0], p1[1])
            ctx.lineTo(p2[0], p2[1])
            ctx.stroke()
          }
        }

        // Active route polyline
        var rpts = nav.miniRoute
        if (Array.isArray(rpts) && rpts.length >= 2) {
          ctx.lineCap = 'round'
          ctx.lineJoin = 'round'
          ctx.beginPath()
          for (var j = 0; j < rpts.length; j++) {
            var rp = toScreen(rpts[j][0], rpts[j][1])
            if (j === 0) ctx.moveTo(rp[0], rp[1])
            else ctx.lineTo(rp[0], rp[1])
          }
          // Casing
          ctx.strokeStyle = 'rgba(10,12,16,0.85)'
          ctx.lineWidth = 7.5
          ctx.stroke()
          // Route fill
          ctx.strokeStyle = nav.isHighwayExit ? '#2b95ff' : '#ff6600'
          ctx.lineWidth = 4.5
          ctx.stroke()
        }

        // Player arrow chevron
        ctx.save()
        ctx.translate(cx, cy)
        if (nav.northUp) ctx.rotate(hdgRad)
        ctx.fillStyle = '#ffffff'
        ctx.strokeStyle = '#0e1116'
        ctx.lineWidth = 1.8
        ctx.beginPath()
        ctx.moveTo(0, -9)
        ctx.lineTo(6.5, 7)
        ctx.lineTo(0, 3.8)
        ctx.lineTo(-6.5, 7)
        ctx.closePath()
        ctx.fill()
        ctx.stroke()
        ctx.restore()

        // North compass marker on outer ring
        var nx = w * 0.5 + Math.sin(rot) * (radius - 11)
        var ny = h * 0.5 - Math.cos(rot) * (radius - 11)
        ctx.fillStyle = '#ff6600'
        ctx.font = '800 10px Overpass, sans-serif'
        ctx.textAlign = 'center'
        ctx.textBaseline = 'middle'
        ctx.fillText('N', nx, ny)

        ctx.restore()
      }

      function applyNav (nav) {
        scope.nav = nav || null
        if (!nav) return

        var design = nav.navDesign || 'gmaps_card'
        scope.designBadge = design === 'gmaps_card' ? '1/3' : (design === 'round_minimap' ? '2/3' : '3/3')

        // Banner color: Highway blue on motorway exits, Google Maps emerald on standard turns
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

        var hdg = ((Number(nav.headingDeg) || 0) % 360 + 360) % 360
        scope.headingText = (hdg < 10 ? '00' : (hdg < 100 ? '0' : '')) + Math.round(hdg) + '°'
        scope.cardinalText = CARDINALS[Math.round(hdg / 45) % 8]
        scope.speedText = (nav.units === 'imperial'
          ? Math.round((Number(nav.speedKph) || 0) * 0.621371) + ' mph'
          : Math.round(Number(nav.speedKph) || 0) + ' km/h')

        // Speed limit badge styling
        if (nav.speedLimitUnlimited) {
          scope.limitBadgeText = '///'
          scope.limitBadgeStyle = { background: '#e5e7eb', color: '#374151', border: '2px solid #4b5563' }
        } else if (nav.speedLimitKph != null && nav.speedLimitKph > 0) {
          var dispLim = nav.units === 'imperial'
            ? Math.round(nav.speedLimitKph * 0.621371)
            : Math.round(nav.speedLimitKph)
          scope.limitBadgeText = String(dispLim)
          scope.limitBadgeStyle = { background: '#ffffff', color: '#111827', border: '3px solid #d92d20' }
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

        if (design === 'round_minimap' && nav.enabled && !scope.hidden) {
          setTimeout(function () { drawRoundMinimap(nav) }, 0)
        }
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

      scope.$on('BeamNGEarthHud', function (_, data) {
        if (!data) return
        scope.$evalAsync(function () {
          scope.hidden = !!data.hidden
          applyNav(data.nav)
        })
      })

      scope.$on('$destroy', function () {
        bngApi.engineLua('if beamngEarth_core then beamngEarth_core.hudApp("nav", false) end')
        if (audioCtx && audioCtx.close) {
          try { audioCtx.close() } catch (e) {}
        }
      })
    }
  }
}])
