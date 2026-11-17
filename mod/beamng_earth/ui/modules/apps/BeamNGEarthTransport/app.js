// BeamNG.Earth Transport Modes HUD app (lua/ge/extensions/beamngEarth/hudapps.lua + transportModes.lua).
// Hidden when no job is active/pending/summarized so idle driving has zero visual clutter.
angular.module('beamng.apps')
.directive('beamngEarthTransport', [function () {
  var CARD = 'background:rgba(12,15,20,0.84);color:#eef1f4;border:1px solid rgba(255,255,255,0.16);' +
    'border-radius:6px;padding:8px 11px;font-size:13px;line-height:1.35;box-shadow:0 3px 12px rgba(0,0,0,0.45);'
  var BTN = 'background:rgba(255,255,255,0.1);color:#eef1f4;border:1px solid rgba(255,255,255,0.22);' +
    'border-radius:4px;padding:3px 9px;font-size:12px;cursor:pointer;'
  var MODE_COLOR = { taxi: '#ffd45a', bus: '#68bfff', logistics: '#ff9d5c' }

  function fmtDist(m, metric) {
    if (m == null || !isFinite(m)) return '-'
    if (metric) return m < 1000 ? Math.round(m / 10) * 10 + ' m' : (m / 1000).toFixed(m < 10000 ? 1 : 0) + ' km'
    var mi = m / 1609.344
    return mi < 0.1 ? Math.round(m * 3.28084) + ' ft' : mi.toFixed(mi < 10 ? 1 : 0) + ' mi'
  }

  function fmtDur(s) {
    if (s == null || !isFinite(s)) return ''
    var sec = Math.max(0, Math.round(s))
    var m = Math.floor(sec / 60), r = sec % 60
    if (m >= 60) return Math.floor(m / 60) + 'h ' + (m % 60) + 'm'
    return m > 0 ? m + 'm ' + (r < 10 ? '0' : '') + r + 's' : r + 's'
  }

  return {
    template:
      '<div class="bngApp" style="width:100%;height:100%;background:transparent;box-shadow:none;overflow:visible;">' +
        '<div ng-if="tr && !hidden" style="' + CARD + '">' +
          '<div ng-if="tr.state === \'pending\'">' +
            '<div style="display:flex;justify-content:space-between;align-items:center;gap:8px;">' +
              '<span style="font-weight:600;">Finding {{ tr.mode }} stops...</span>' +
              '<button ng-click="cancel()" style="' + BTN + '">Cancel</button>' +
            '</div>' +
          '</div>' +
          '<div ng-if="tr.state === \'active\'">' +
            '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:3px;">' +
              '<span ng-style="{color: modeColor}" style="font-weight:700;font-size:11px;letter-spacing:0.05em;text-transform:uppercase;">{{ tr.mode }}</span>' +
              '<span style="font-weight:600;font-size:12px;color:#cdd6df;">Stop {{ tr.stopIndex }}/{{ tr.stopCount }}</span>' +
            '</div>' +
            '<div style="font-weight:600;color:#fff;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ tr.stopName }}</div>' +
            '<div ng-if="tr.stopAddress" style="font-size:11px;color:#9aa4ae;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ tr.stopAddress }}</div>' +
            '<div style="display:flex;gap:10px;margin-top:4px;font-size:12px;color:#d6dee6;">' +
              '<span ng-if="tr.distM != null">Next: <b>{{ distText }}</b></span>' +
              '<span ng-if="etaText">ETA: <b>{{ etaText }}</b></span>' +
              '<span>Score: <b>{{ tr.score }}</b></span>' +
            '</div>' +
            '<div ng-if="tr.dwellFrac > 0" style="margin-top:5px;">' +
              '<div style="font-size:11px;color:#6ae696;margin-bottom:2px;">Hold stop ({{ dwellPct }}%)</div>' +
              '<div style="height:4px;background:rgba(255,255,255,0.16);border-radius:2px;overflow:hidden;">' +
                '<div ng-style="{width: dwellPct + \'%\'}" style="height:100%;background:#3ddc84;"></div>' +
              '</div>' +
            '</div>' +
            '<div style="display:flex;gap:6px;margin-top:6px;">' +
              '<button ng-click="skip()" style="' + BTN + '">Skip Stop</button>' +
              '<button ng-click="cancel()" style="' + BTN + '">Cancel</button>' +
            '</div>' +
          '</div>' +
          '<div ng-if="tr.state === \'summary\'">' +
            '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:4px;">' +
              '<span ng-style="{color: modeColor}" style="font-weight:700;font-size:11px;text-transform:uppercase;">{{ tr.mode }} · Complete</span>' +
              '<span style="font-weight:700;color:#6ae696;">{{ tr.score }}/100</span>' +
            '</div>' +
            '<div style="font-size:12px;color:#d6dee6;">Stops {{ tr.stopsCompleted }}/{{ tr.stopCount }} · {{ summaryDist }} · {{ summaryTime }}</div>' +
            '<div style="font-size:11px;color:#9aa4ae;margin-top:2px;">Smoothness {{ tr.smoothnessPct }}% · Collisions {{ tr.collisions }}</div>' +
            '<div style="margin-top:6px;">' +
              '<button ng-click="dismiss()" style="' + BTN + '">Dismiss</button>' +
            '</div>' +
          '</div>' +
        '</div>' +
      '</div>',
    replace: true,
    link: function (scope, element) {
      'use strict'
      scope.tr = null
      scope.hidden = false
      scope.modeColor = MODE_COLOR.taxi
      scope.distText = ''
      scope.etaText = ''
      scope.dwellPct = 0
      scope.summaryDist = ''
      scope.summaryTime = ''

      var unclipped = false
      function unclip () {
        if (unclipped) return
        var el = element && element[0]
        var host = el && el.closest ? el.closest('.ui-app-host') : null
        if (host) { host.style.overflow = 'visible'; unclipped = true }
      }

      var hello = function (on) {
        bngApi.engineLua('if beamngEarth_core and beamngEarth_core.hudApp then beamngEarth_core.hudApp("transport", ' + on + ') end')
      }

      scope.skip = function () {
        bngApi.engineLua('if beamngEarth_transportModes then beamngEarth_transportModes.skipStop() end')
      }
      scope.cancel = function () {
        bngApi.engineLua('if beamngEarth_transportModes then beamngEarth_transportModes.cancelJob() end')
      }
      scope.dismiss = function () {
        bngApi.engineLua('if beamngEarth_transportModes then beamngEarth_transportModes.dismissSummary() end')
      }

      scope.$on('BeamNGEarthHud', function (event, data) {
        scope.$evalAsync(function () {
          var tr = (data && data.transport) || null
          scope.tr = tr
          scope.hidden = !!(data && data.hidden)
          if (tr) {
            scope.modeColor = MODE_COLOR[tr.mode] || MODE_COLOR.taxi
            scope.distText = fmtDist(tr.distM, !!tr.metric)
            scope.etaText = tr.etaS != null ? fmtDur(tr.etaS) : ''
            scope.dwellPct = Math.round(Math.max(0, Math.min(1, tr.dwellFrac || 0)) * 100)
            if (tr.state === 'summary') {
              scope.summaryDist = fmtDist(tr.drivenM, !!tr.metric)
              scope.summaryTime = fmtDur(tr.elapsedS)
            }
          }
          unclip()
        })
      })

      hello(true)
      var again = setInterval(function () { hello(true) }, 3000)
      scope.$on('$destroy', function () { clearInterval(again); hello(false) })
    }
  }
}]);
