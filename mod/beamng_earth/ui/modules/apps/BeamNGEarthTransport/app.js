// BeamNG.Earth Transport Modes HUD app (lua/ge/extensions/beamngEarth/hudapps.lua + transportModes.lua).
// Hidden when no job is active/pending/summarized so idle driving has zero visual clutter.
angular.module('beamng.apps')
.directive('beamngEarthTransport', [function () {
  var CARD = 'background:rgba(16,20,26,0.90);color:#edf1f6;border:1px solid rgba(255,255,255,0.12);' +
    'border-radius:6px;padding:9px 12px;font-size:13px;line-height:1.35;box-shadow:0 4px 16px rgba(0,0,0,0.48);'
  var BTN = 'background:rgba(255,255,255,0.07);color:#e4ebf2;border:1px solid rgba(255,255,255,0.16);' +
    'border-radius:4px;padding:3px 9px;font-size:11px;font-weight:600;cursor:pointer;'
  var NUM = 'font-variant-numeric:tabular-nums;'
  var MODE_STYLE = {
    taxi: { color: '#f59e0b', bg: 'rgba(245,158,11,0.18)', border: 'rgba(245,158,11,0.45)' },
    bus: { color: '#38bdf8', bg: 'rgba(56,189,248,0.18)', border: 'rgba(56,189,248,0.45)' },
    logistics: { color: '#ff6600', bg: 'rgba(255,102,0,0.18)', border: 'rgba(255,102,0,0.45)' },
    parcel: { color: '#34d399', bg: 'rgba(52,211,153,0.18)', border: 'rgba(52,211,153,0.45)' }
  }

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
        '<div ng-if="tr && !hidden" ng-style="{\'border-left\': \'3px solid \' + modeStyle.color}" style="' + CARD + '">' +
          '<div ng-if="tr.state === \'pending\'">' +
            '<div style="display:flex;justify-content:space-between;align-items:center;gap:8px;">' +
              '<span style="font-weight:600;letter-spacing:0.01em;">Finding {{ tr.mode }} stops...</span>' +
              '<button ng-click="cancel()" style="' + BTN + '">Cancel</button>' +
            '</div>' +
          '</div>' +
          '<div ng-if="tr.state === \'active\'">' +
            '<div style="display:flex;justify-content:space-between;align-items:center;gap:6px;margin-bottom:5px;">' +
              '<div style="display:flex;align-items:center;gap:5px;min-width:0;flex-wrap:wrap;">' +
                '<span ng-style="{color: modeStyle.color, background: modeStyle.bg, borderColor: modeStyle.border}" ' +
                  'style="padding:1px 6px;border-radius:3px;border:1px solid transparent;font-weight:700;font-size:10px;letter-spacing:0.05em;text-transform:uppercase;">{{ tr.mode }}</span>' +
                '<span ng-style="{color: stopTypeColor, background: stopTypeBg}" ' +
                  'style="padding:1px 6px;border-radius:3px;font-weight:600;font-size:10px;letter-spacing:0.02em;white-space:nowrap;">{{ stopTypeLabel }}</span>' +
                '<span ng-if="stopSectorLabel" style="padding:1px 5px;border-radius:3px;font-weight:600;font-size:10px;color:#b4c5d6;background:rgba(255,255,255,0.08);border:1px solid rgba(255,255,255,0.12);white-space:nowrap;">{{ stopSectorLabel }}</span>' +
              '</div>' +
              '<span style="font-weight:600;font-size:11px;color:#b8c4d0;white-space:nowrap;' + NUM + '">{{ tr.mode === \'taxi\' ? (tr.passengerOnBoard ? \'Drop-off\' : \'Pickup\') : (\'Stop \' + tr.stopIndex + \'/\' + tr.stopCount) }}</span>' +
            '</div>' +
            '<div style="font-weight:600;font-size:13.5px;color:#fff;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ tr.stopName }}</div>' +
            '<div ng-if="stopSubtitle" style="font-size:11px;color:#93a0ad;margin-top:1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ stopSubtitle }}</div>' +
            '<div ng-if="subText" style="display:flex;justify-content:space-between;align-items:center;gap:6px;margin-top:4px;font-size:11px;color:#cdd6df;' + NUM + '">' +
              '<span>{{ subText }}</span>' +
              '<span ng-if="subBadge" ng-style="tr.trailerMissing ? {background:\'rgba(245,158,11,0.22)\',color:\'#fbbf24\'} : {}" style="padding:1px 5px;border-radius:3px;background:rgba(61,220,132,0.16);color:#6ae696;font-size:10px;font-weight:600;white-space:nowrap;">{{ subBadge }}</span>' +
            '</div>' +
            '<div ng-if="tr.mode === \'bus\' && tr.nextStopName" style="font-size:11px;color:#93a0ad;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">Next Stop after this: {{ tr.nextStopName }}</div>' +
            '<div style="display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px;margin-top:6px;padding-top:5px;border-top:1px solid rgba(255,255,255,0.08);font-size:12px;color:#cdd6df;' + NUM + '">' +
              '<div><span style="color:#8c99a6;font-size:10px;display:block;text-transform:uppercase;">Next</span><b style="color:#fff;">{{ tr.distM != null ? distText : \'-\' }}</b></div>' +
              '<div><span style="color:#8c99a6;font-size:10px;display:block;text-transform:uppercase;">ETA</span><b style="color:#fff;">{{ etaText || \'-\' }}</b></div>' +
              '<div style="text-align:right;"><span style="color:#8c99a6;font-size:10px;display:block;text-transform:uppercase;">Score</span><b style="color:#fff;">{{ tr.score }}/100</b></div>' +
            '</div>' +
            '<div ng-if="tr.trailerMissing" style="margin-top:5px;font-size:11px;color:#fbbf24;font-weight:600;">' +
              '{{ tr.bayHint || \'Trailer missing · Go back &amp; hitch your trailer\' }}' +
            '</div>' +
            '<div ng-if="!tr.trailerMissing && tr.dwellFrac > 0" style="margin-top:6px;">' +
              '<div style="display:flex;justify-content:space-between;font-size:11px;margin-bottom:3px;font-weight:600;' + NUM + '" ng-style="{color: dwellTextColor}">' +
                '<span>{{ dwellLabel }}</span>' +
                '<span>{{ dwellTimer }}</span>' +
              '</div>' +
              '<div style="height:6px;background:rgba(255,255,255,0.14);border-radius:3px;overflow:hidden;">' +
                '<div ng-style="{width: dwellPct + \'%\', background: dwellBarColor}" style="height:100%;transition:width 0.14s linear;"></div>' +
              '</div>' +
            '</div>' +
            '<div ng-if="!tr.trailerMissing && tr.dwellFrac <= 0 && tr.distM != null && tr.distM <= (tr.trailerState === \'staged\' ? 50 : 35)" style="margin-top:5px;font-size:11px;color:#7dd3fc;">' +
              '{{ tr.trailerState === \'staged\' ? \'Back up to hitch staged trailer\' : \'Pull into bay &amp; stop\' }}' +
            '</div>' +
            '<div style="display:flex;gap:6px;margin-top:7px;">' +
              '<button ng-click="skip()" style="flex:1;' + BTN + '">Skip Stop</button>' +
              '<button ng-click="cancel()" style="' + BTN + '">Cancel</button>' +
            '</div>' +
          '</div>' +
          '<div ng-if="tr.state === \'summary\'">' +
            '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:5px;">' +
              '<span ng-style="{color: modeStyle.color}" style="font-weight:700;font-size:11px;letter-spacing:0.04em;text-transform:uppercase;">{{ tr.mode }} · Complete</span>' +
              '<span style="font-weight:700;color:#f59e0b;' + NUM + '" ng-if="tr.totalEarned > 0">+${{ tr.totalEarned.toFixed(2) }} · <span style="color:#6ae696;">{{ tr.score }}/100</span></span>' +
              '<span style="font-weight:700;color:#6ae696;' + NUM + '" ng-if="!(tr.totalEarned > 0)">{{ tr.score }}/100</span>' +
            '</div>' +
            '<div style="font-size:12px;color:#d6dee6;' + NUM + '">{{ tr.mode === \'taxi\' ? (tr.stopsCompleted >= 2 ? \'Pickup -> Drop-off\' : \'Ride Skipped\') : (\'Stops \' + tr.stopsCompleted + \'/\' + tr.stopCount) }} · {{ summaryDist }} · {{ summaryTime }}</div>' +
            '<div ng-if="tr.mode === \'taxi\' && tr.totalFare > 0" style="font-size:11.5px;color:#fbbf24;margin-top:2px;font-weight:600;' + NUM + '">Fare ${{ tr.fare.toFixed(2) }} + Tip ${{ tr.tip.toFixed(2) }}</div>' +
            '<div ng-if="tr.mode === \'parcel\'" style="font-size:11.5px;color:#6ee7b7;margin-top:2px;font-weight:600;' + NUM + '">Parcels {{ tr.parcelsDelivered || 0 }}/{{ tr.parcelsTotal || 0 }}<span ng-if="tr.parcelsReturned > 0"> (+{{ tr.parcelsReturned }} returns)</span></div>' +
            '<div style="font-size:11px;color:#93a0ad;margin-top:2px;' + NUM + '">Smoothness {{ tr.smoothnessPct }}% · Collisions {{ tr.collisions }}<span ng-if="tr.driverRank"> · {{ tr.driverRank }}</span></div>' +
            '<div style="display:flex;gap:6px;margin-top:7px;">' +
              '<button ng-if="tr.mode === \'taxi\'" ng-click="nextPassenger()" style="flex:1;background:#ff6600;color:#fff;border:1px solid #ff7a1f;border-radius:4px;padding:3px 9px;font-size:11px;font-weight:700;cursor:pointer;">Next Passenger</button>' +
              '<button ng-click="dismiss()" style="flex:1;' + BTN + '">Dismiss</button>' +
            '</div>' +
          '</div>' +
        '</div>' +
      '</div>',
    replace: true,
    link: function (scope, element) {
      'use strict'
      scope.tr = null
      scope.hidden = false
      scope.modeStyle = MODE_STYLE.taxi
      scope.stopTypeLabel = 'Kerbside Stop'
      scope.stopTypeColor = '#b4c5d6'
      scope.stopTypeBg = 'rgba(255,255,255,0.08)'
      scope.distText = ''
      scope.etaText = ''
      scope.dwellPct = 0
      scope.dwellLabel = 'Hold in bay'
      scope.dwellTimer = ''
      scope.dwellTextColor = '#6ae696'
      scope.dwellBarColor = '#3ddc84'
      scope.subText = ''
      scope.subBadge = ''
      scope.stopSubtitle = ''
      scope.stopSectorLabel = ''
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
      scope.nextPassenger = function () {
        bngApi.engineLua('if beamngEarth_transportModes then beamngEarth_transportModes.nextPassenger() end')
      }

      scope.$on('BeamNGEarthHud', function (event, data) {
        scope.$evalAsync(function () {
          var tr = (data && data.transport) || null
          scope.tr = tr
          scope.hidden = !!(data && data.hidden)
          if (tr) {
            scope.modeStyle = MODE_STYLE[tr.mode] || MODE_STYLE.taxi
            var isBay = tr.stopType === 'loading_bay'
            scope.stopTypeLabel = isBay ? 'Loading Bay' : 'Kerbside Stop'
            scope.stopTypeColor = isBay ? '#7dd3fc' : '#b4c5d6'
            scope.stopTypeBg = isBay ? 'rgba(56,189,248,0.15)' : 'rgba(255,255,255,0.08)'
            scope.stopSectorLabel = tr.stopSectorLabel || ''
            var addr = (tr.stopAddress || '').trim()
            var loc = (tr.stopLocality || '').trim()
            if (addr && loc) {
              scope.stopSubtitle = addr.toLowerCase().indexOf(loc.toLowerCase()) >= 0 ? addr : (addr + ' · ' + loc)
            } else {
              scope.stopSubtitle = addr || loc
            }
            scope.distText = fmtDist(tr.distM, !!tr.metric)
            scope.etaText = tr.etaS != null ? fmtDur(tr.etaS) : ''
            scope.dwellPct = Math.round(Math.max(0, Math.min(1, tr.dwellFrac || 0)) * 100)
            var isFallback = tr.dwellMode === 'fallback'
            var targetS = tr.dwellTargetS || (isFallback ? 5.0 : 2.5)
            var curS = tr.dwellS != null ? tr.dwellS : ((tr.dwellFrac || 0) * targetS)
            var remS = Math.max(0, targetS - curS)
            scope.dwellLabel = tr.dwellLabel || (isFallback ? 'Kerbside fallback' : 'Hold in bay')
            scope.dwellTimer = curS.toFixed(1) + ' / ' + targetS.toFixed(1) + ' s (' + remS.toFixed(1) + 's)'
            scope.dwellTextColor = isFallback ? '#c8e972' : '#6ae696'
            scope.dwellBarColor = isFallback ? '#a9d94c' : '#3ddc84'
            scope.subText = ''
            scope.subBadge = ''
            if (tr.mode === 'taxi') {
              var paxTxt = (tr.paxCount || 1) + ' pax'
              scope.subText = tr.passengerOnBoard ? (paxTxt + ' · Meter $' + Number(tr.fare || 0).toFixed(2)) : ('En route to pickup · ' + paxTxt)
              if (tr.rideArchetype === 'express') scope.subBadge = 'Express +40%'
              else if (tr.rideArchetype === 'vip') scope.subBadge = 'VIP +35% tip'
              else scope.subBadge = tr.passengerOnBoard ? 'On Board' : 'Pickup'
            } else if (tr.mode === 'bus') {
              scope.subText = (tr.paxCount != null ? tr.paxCount : 0) + '/' + (tr.paxCapacity || 40) + ' pax'
              scope.subBadge = tr.scheduleText || 'On Time'
            } else if (tr.mode === 'logistics') {
              if (tr.legKind === 'deadhead') {
                scope.subText = tr.legLabel || 'Deadhead · Empty transit (0 kg)'
              } else if (tr.legLabel) {
                scope.subText = tr.legLabel
              } else if (tr.cargoKg) {
                var wt = tr.cargoKg >= 1000 ? (tr.cargoKg / 1000).toFixed(1) + ' t' : Math.round(tr.cargoKg) + ' kg'
                scope.subText = (tr.cargoLabel || 'Cargo') + ' · ' + wt
              } else {
                scope.subText = 'Deadhead · Empty transit (0 kg)'
              }
              if (tr.trailerMissing) scope.subBadge = 'Trailer Missing'
              else if (tr.trailerState === 'staged') scope.subBadge = 'Hook Up'
              else if (tr.trailerState === 'attached') scope.subBadge = 'Trailer'
              else if (tr.legKind === 'deadhead') scope.subBadge = 'Deadhead'
              else if (tr.legKind === 'pickup_approach') scope.subBadge = 'Pickup'
              else scope.subBadge = 'Solo'
            } else if (tr.mode === 'parcel') {
              var pRem = tr.parcelsRemaining != null ? tr.parcelsRemaining : 0
              var pTot = tr.parcelsTotal != null ? tr.parcelsTotal : 0
              var pWt = Math.round(tr.cargoCurrentKg || 0) + ' kg'
              var pCnt = tr.parcelCount || 1
              var pRec = tr.recipient ? (tr.recipient + ' · ') : ''
              scope.subText = pRec + pRem + '/' + pTot + ' left · ' + pWt
              scope.subBadge = tr.parcelAction === 'pickup_return' ? ('Return +' + pCnt) : ('Deliver ' + pCnt + 'x')
            }
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
