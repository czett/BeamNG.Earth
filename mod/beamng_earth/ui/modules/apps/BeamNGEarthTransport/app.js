// BeamNG.Earth Transport Modes HUD app (lua/ge/extensions/beamngEarth/hudapps.lua + transportModes.lua).
// Styled with native BeamNG HUD surfaces, Overpass typography, and --bng-* color tokens.
// Hidden when no job is active/pending/summarized so idle driving has zero visual clutter.
angular.module('beamng.apps')
.directive('beamngEarthTransport', [function () {
  var CARD = 'background:rgba(var(--bng-off-black-rgb,26,26,26),0.78);color:var(--bng-off-white,#f0f0f0);' +
    'border-radius:var(--bng-corners-2,0.5rem);padding:8px 11px;font-family:"Overpass",var(--fnt-defs,sans-serif);' +
    'font-size:13px;line-height:1.35;'
  var RIBBON = 'display:inline-block;width:0.35em;height:0.95em;margin-right:6px;vertical-align:-1px;' +
    'transform:matrix(0.94,0,-0.38,1,0,0);background:var(--bng-orange-b400,#ff6600);'
  var BTN = 'background:rgba(var(--bng-ter-blue-gray-800-rgb,45,52,64),0.82);color:var(--bng-off-white,#f0f0f0);' +
    'border:1px solid rgba(var(--bng-cool-gray-500-rgb,130,136,148),0.45);border-radius:var(--bng-corners-1,0.25rem);' +
    'padding:3px 10px;font-family:"Overpass",var(--fnt-defs,sans-serif);font-size:11.5px;font-weight:700;cursor:pointer;'
  var PRIMARY_BTN = 'background:var(--bng-orange-b400,#ff6600);color:var(--bng-off-white,#fff);' +
    'border:1px solid var(--bng-orange-400,#ff6600);border-radius:var(--bng-corners-1,0.25rem);' +
    'padding:3px 10px;font-family:"Overpass",var(--fnt-defs,sans-serif);font-size:11.5px;font-weight:700;cursor:pointer;'
  var PILL = 'padding:1px 6px;border-radius:var(--bng-corners-1,0.25rem);font-weight:700;font-size:10px;' +
    'letter-spacing:0.03em;white-space:nowrap;'
  var NUM = 'font-variant-numeric:tabular-nums;'
  var MODE_ACCENT = {
    taxi: 'var(--bng-ter-yellow-400,#e0b020)',
    bus: 'var(--bng-add-blue-400,#5299e0)',
    logistics: 'var(--bng-orange-b400,#ff6600)',
    parcel: 'var(--bng-add-green-400,#44c078)'
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
        '<div ng-if="tr && !hidden" style="' + CARD + '">' +
          '<div ng-if="tr.state === \'refueling\' && tr.refueling">' +
            '<div style="display:flex;justify-content:space-between;align-items:center;gap:8px;margin-bottom:5px;font-size:12px;' + NUM + '">' +
              '<span style="font-weight:800;font-style:italic;"><span style="' + RIBBON + 'background:var(--bng-add-blue-400,#5299e0);"></span>{{ refuelTitle }}</span>' +
              '<span ng-if="refuelReceipt" style="font-weight:700;color:var(--bng-add-blue-200,#9cc8f0);white-space:nowrap;">{{ refuelReceipt }}</span>' +
            '</div>' +
            '<div style="height:6px;background:rgba(255,255,255,0.15);overflow:hidden;">' +
              '<div ng-style="{width: refuelBarPct + \'%\'}" style="height:100%;background:var(--bng-add-blue-400,#5299e0);"></div>' +
            '</div>' +
          '</div>' +
          '<div ng-if="tr.state === \'pending\'">' +
            '<div style="display:flex;justify-content:space-between;align-items:center;gap:8px;">' +
              '<span style="font-weight:700;font-style:italic;"><span ng-style="{background: modeAccent}" style="' + RIBBON + '"></span>Finding {{ tr.mode }} stops...</span>' +
              '<button ng-click="cancel()" style="' + BTN + '">Cancel</button>' +
            '</div>' +
          '</div>' +
          '<div ng-if="tr.state === \'active\'">' +
            '<div style="display:flex;justify-content:space-between;align-items:center;gap:6px;margin-bottom:5px;">' +
              '<div style="display:flex;align-items:center;gap:5px;min-width:0;flex-wrap:wrap;">' +
                '<span style="font-weight:800;font-style:italic;font-size:12.5px;text-transform:uppercase;letter-spacing:0.03em;">' +
                  '<span ng-style="{background: modeAccent}" style="' + RIBBON + '"></span>{{ tr.mode }}' +
                '</span>' +
                '<span style="' + PILL + 'background:var(--bng-ter-blue-gray-800,#303846);color:var(--bng-cool-gray-100,#dadde2);">{{ stopTypeLabel }}</span>' +
                '<span ng-if="stopSectorLabel" style="' + PILL + 'background:rgba(var(--bng-ter-blue-gray-700-rgb,58,68,82),0.65);color:var(--bng-cool-gray-200,#c8ccd4);">{{ stopSectorLabel }}</span>' +
              '</div>' +
              '<div style="display:flex;align-items:center;gap:6px;white-space:nowrap;' + NUM + '">' +
                '<span ng-if="tr.fuelPct != null" ng-style="tr.lowFuel ? {background:\'var(--bng-ter-yellow-700,#6b5816)\',color:\'var(--bng-off-white,#f0f0f0)\'} : {background:\'var(--bng-ter-blue-gray-800,#303846)\',color:\'var(--bng-cool-gray-200,#c8ccd4)\'}" style="' + PILL + '">Fuel {{ tr.fuelPct }}%</span>' +
                '<span style="font-weight:700;font-size:11.5px;color:var(--bng-cool-gray-200,#c8ccd4);">{{ tr.mode === \'taxi\' ? (tr.passengerOnBoard ? \'Drop-off\' : \'Pickup\') : (\'Stop \' + tr.stopIndex + \'/\' + tr.stopCount) }}</span>' +
              '</div>' +
            '</div>' +
            '<div style="font-weight:700;font-size:14px;color:var(--bng-off-white,#f0f0f0);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ tr.stopName }}</div>' +
            '<div ng-if="stopSubtitle" style="font-size:11.5px;color:var(--bng-cool-gray-300,#b4b8c2);margin-top:1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ stopSubtitle }}</div>' +
            '<div ng-if="subText" style="display:flex;justify-content:space-between;align-items:center;gap:6px;margin-top:4px;font-size:11.5px;color:var(--bng-cool-gray-200,#c8ccd4);' + NUM + '">' +
              '<span>{{ subText }}</span>' +
              '<span ng-if="subBadge" ng-style="tr.trailerMissing ? {background:\'var(--bng-ter-yellow-700,#6b5816)\',color:\'var(--bng-off-white,#f0f0f0)\'} : {background:\'var(--bng-add-green-700,#1f6640)\',color:\'var(--bng-off-white,#f0f0f0)\'}" style="' + PILL + '">{{ subBadge }}</span>' +
            '</div>' +
            '<div ng-if="tr.mode === \'bus\' && tr.nextStopName" style="font-size:11px;color:var(--bng-cool-gray-300,#b4b8c2);margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">Next Stop after this: {{ tr.nextStopName }}</div>' +
            '<div style="display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px;margin-top:6px;padding-top:5px;border-top:1px solid rgba(255,255,255,0.12);font-size:12px;' + NUM + '">' +
              '<div><span style="color:var(--bng-cool-gray-300,#b4b8c2);font-size:10px;display:block;text-transform:uppercase;">Next</span><b style="color:var(--bng-off-white,#f0f0f0);">{{ tr.distM != null ? distText : \'-\' }}</b></div>' +
              '<div><span style="color:var(--bng-cool-gray-300,#b4b8c2);font-size:10px;display:block;text-transform:uppercase;">ETA</span><b style="color:var(--bng-off-white,#f0f0f0);">{{ etaText || \'-\' }}</b></div>' +
              '<div style="text-align:right;"><span style="color:var(--bng-cool-gray-300,#b4b8c2);font-size:10px;display:block;text-transform:uppercase;">Score</span><b style="color:var(--bng-off-white,#f0f0f0);">{{ tr.score }}/100</b></div>' +
            '</div>' +
            '<div ng-if="tr.cargoSensitivity === \'fragile\' || tr.cargoSensitivity === \'hazmat\'" style="margin-top:6px;padding:5px 7px;border-radius:var(--bng-corners-1,0.25rem);background:rgba(var(--bng-ter-blue-gray-900-rgb,28,32,40),0.75);">' +
              '<div style="display:flex;justify-content:space-between;align-items:center;gap:6px;font-size:11px;margin-bottom:3px;' + NUM + '">' +
                '<div style="display:flex;align-items:center;gap:5px;min-width:0;">' +
                  '<span ng-style="tr.cargoSensitivity === \'hazmat\' ? {background:\'var(--bng-add-red-700,#7a2620)\',color:\'var(--bng-off-white,#f0f0f0)\'} : {background:\'var(--bng-ter-yellow-700,#6b5816)\',color:\'var(--bng-off-white,#f0f0f0)\'}" ' +
                    'style="' + PILL + '">{{ tr.cargoSensitivity === \'hazmat\' ? \'GEFAHRGUT · +50%\' : \'FRAGILE · +35%\' }}</span>' +
                  '<span ng-if="tr.sensitivityLabel" style="color:var(--bng-cool-gray-200,#c8ccd4);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ tr.sensitivityLabel }}</span>' +
                '</div>' +
                '<b ng-style="{color: integrityColor}" style="white-space:nowrap;">{{ integrityPct }}%</b>' +
              '</div>' +
              '<div style="height:5px;background:rgba(255,255,255,0.15);overflow:hidden;">' +
                '<div ng-style="{width: integrityPct + \'%\', background: integrityColor}" style="height:100%;"></div>' +
              '</div>' +
            '</div>' +
            '<div ng-if="tr.trailerMissing" style="margin-top:5px;font-size:11.5px;color:var(--bng-ter-yellow-300,#e8c448);font-weight:700;">' +
              '{{ tr.bayHint || \'Trailer missing · Go back &amp; hitch your trailer\' }}' +
            '</div>' +
            '<div ng-if="!tr.trailerMissing && tr.dwellFrac > 0" style="margin-top:6px;">' +
              '<div style="display:flex;justify-content:space-between;font-size:11px;margin-bottom:3px;font-weight:700;font-style:italic;' + NUM + '" ng-style="{color: dwellTextColor}">' +
                '<span>{{ dwellLabel }}</span>' +
                '<span>{{ dwellTimer }}</span>' +
              '</div>' +
              '<div style="height:6px;background:rgba(255,255,255,0.15);overflow:hidden;">' +
                '<div ng-style="{width: dwellPct + \'%\', background: dwellBarColor}" style="height:100%;"></div>' +
              '</div>' +
            '</div>' +
            '<div ng-if="!tr.trailerMissing && tr.dwellFrac <= 0 && tr.distM != null && tr.distM <= (tr.trailerState === \'staged\' ? 50 : 35)" style="margin-top:5px;font-size:11.5px;color:var(--bng-add-blue-200,#9cc8f0);">' +
              '{{ tr.trailerState === \'staged\' ? \'Back up to hitch staged trailer\' : \'Pull into bay &amp; stop\' }}' +
            '</div>' +
            '<div ng-if="tr.refueling && (tr.refueling.active || tr.refueling.done || tr.refueling.holdS > 0)" style="margin-top:6px;padding:5px 7px;border-radius:var(--bng-corners-1,0.25rem);background:rgba(var(--bng-ter-blue-gray-900-rgb,28,32,40),0.82);">' +
              '<div style="display:flex;justify-content:space-between;align-items:center;gap:6px;font-size:11px;margin-bottom:3px;' + NUM + '">' +
                '<span style="font-weight:700;color:var(--bng-off-white,#f0f0f0);">{{ refuelTitle }}</span>' +
                '<span ng-if="refuelReceipt" style="font-weight:700;color:var(--bng-add-blue-200,#9cc8f0);white-space:nowrap;">{{ refuelReceipt }}</span>' +
              '</div>' +
              '<div style="height:5px;background:rgba(255,255,255,0.15);overflow:hidden;">' +
                '<div ng-style="{width: refuelBarPct + \'%\'}" style="height:100%;background:var(--bng-add-blue-400,#5299e0);"></div>' +
              '</div>' +
            '</div>' +
            '<div ng-if="tr.lowFuel && !(tr.refueling && tr.refueling.active)" style="display:flex;justify-content:space-between;align-items:center;gap:6px;margin-top:5px;padding:4px 7px;border-radius:var(--bng-corners-1,0.25rem);background:rgba(var(--bng-ter-yellow-800-rgb,72,58,18),0.55);font-size:11px;">' +
              '<span style="color:var(--bng-ter-yellow-200,#f0d466);font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ lowFuelText }}</span>' +
              '<button ng-click="findFuel()" style="' + PRIMARY_BTN + 'padding:2px 8px;font-size:10.5px;white-space:nowrap;">Find Fuel</button>' +
            '</div>' +
            '<div style="display:flex;gap:6px;margin-top:7px;">' +
              '<button ng-click="skip()" style="flex:1;' + BTN + '">Skip Stop</button>' +
              '<button ng-click="cancel()" style="' + BTN + '">Cancel</button>' +
            '</div>' +
          '</div>' +
          '<div ng-if="tr.state === \'summary\'">' +
            '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:5px;">' +
              '<span style="font-weight:800;font-style:italic;font-size:12px;letter-spacing:0.03em;text-transform:uppercase;">' +
                '<span ng-style="{background: modeAccent}" style="' + RIBBON + '"></span>{{ tr.mode }} · Complete' +
              '</span>' +
              '<span style="font-weight:700;color:var(--bng-orange-300,#ff944d);' + NUM + '" ng-if="tr.totalEarned > 0">+${{ tr.totalEarned.toFixed(2) }} · <span style="color:var(--bng-add-green-300,#66d492);">{{ tr.score }}/100</span></span>' +
              '<span style="font-weight:700;color:var(--bng-add-green-300,#66d492);' + NUM + '" ng-if="!(tr.totalEarned > 0)">{{ tr.score }}/100</span>' +
            '</div>' +
            '<div style="font-size:12px;color:var(--bng-cool-gray-100,#dadde2);' + NUM + '">{{ tr.mode === \'taxi\' ? (tr.stopsCompleted >= 2 ? \'Pickup -> Drop-off\' : \'Ride Skipped\') : (\'Stops \' + tr.stopsCompleted + \'/\' + tr.stopCount) }} · {{ summaryDist }} · {{ summaryTime }}</div>' +
            '<div ng-if="tr.mode === \'taxi\' && tr.totalFare > 0" style="font-size:11.5px;color:var(--bng-orange-200,#ffb380);margin-top:2px;font-weight:600;' + NUM + '">Fare ${{ tr.fare.toFixed(2) }} + Tip ${{ tr.tip.toFixed(2) }}</div>' +
            '<div ng-if="tr.mode === \'parcel\'" style="font-size:11.5px;color:var(--bng-add-green-300,#66d492);margin-top:2px;font-weight:600;' + NUM + '">Parcels {{ tr.parcelsDelivered || 0 }}/{{ tr.parcelsTotal || 0 }}<span ng-if="tr.parcelsReturned > 0"> (+{{ tr.parcelsReturned }} returns)</span></div>' +
            '<div ng-if="(tr.cargoSensitivity === \'fragile\' || tr.cargoSensitivity === \'hazmat\') && tr.payout && tr.payout.hazardBonus > 0" style="font-size:11.5px;color:var(--bng-add-green-300,#66d492);margin-top:2px;font-weight:600;' + NUM + '">{{ tr.cargoSensitivity === \'hazmat\' ? \'Gefahrgut Bonus\' : \'Fragile Bonus\' }} +${{ tr.payout.hazardBonus.toFixed(2) }} ({{ integrityPct }}% integrity)</div>' +
            '<div style="font-size:11px;color:var(--bng-cool-gray-300,#b4b8c2);margin-top:2px;' + NUM + '">Smoothness {{ tr.smoothnessPct }}% · Collisions {{ tr.collisions }}<span ng-if="tr.driverRank"> · {{ tr.driverRank }}</span></div>' +
            '<div style="display:flex;gap:6px;margin-top:7px;">' +
              '<button ng-if="tr.mode === \'taxi\'" ng-click="nextPassenger()" style="flex:1;' + PRIMARY_BTN + '">Next Passenger</button>' +
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
      scope.modeAccent = MODE_ACCENT.taxi
      scope.stopTypeLabel = 'Kerbside Stop'
      scope.distText = ''
      scope.etaText = ''
      scope.dwellPct = 0
      scope.dwellLabel = 'Hold in bay'
      scope.dwellTimer = ''
      scope.dwellTextColor = 'var(--bng-add-green-300,#66d492)'
      scope.dwellBarColor = 'var(--bng-add-green-400,#44c078)'
      scope.subText = ''
      scope.subBadge = ''
      scope.stopSubtitle = ''
      scope.stopSectorLabel = ''
      scope.summaryDist = ''
      scope.summaryTime = ''
      scope.refuelTitle = ''
      scope.refuelReceipt = ''
      scope.refuelBarPct = 0
      scope.lowFuelText = 'Low Fuel'

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
      scope.findFuel = function () {
        bngApi.engineLua('if beamngEarth_transportModes then beamngEarth_transportModes.routeToNearestFuel() end')
      }

      scope.$on('BeamNGEarthHud', function (event, data) {
        scope.$evalAsync(function () {
          var tr = (data && data.transport) || null
          scope.tr = tr
          scope.hidden = !!(data && data.hidden)
          if (tr) {
            scope.modeAccent = MODE_ACCENT[tr.mode] || MODE_ACCENT.taxi
            var isBay = tr.stopType === 'loading_bay'
            scope.stopTypeLabel = isBay ? 'Loading Bay' : 'Kerbside Stop'
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
            scope.dwellTextColor = isFallback ? 'var(--bng-ter-yellow-300,#e8c448)' : 'var(--bng-add-green-300,#66d492)'
            scope.dwellBarColor = isFallback ? 'var(--bng-ter-yellow-400,#e0b020)' : 'var(--bng-add-green-400,#44c078)'
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
            var ipct = tr.cargoIntegrity != null ? Math.max(0, Math.min(100, Math.round(tr.cargoIntegrity))) : 100
            scope.integrityPct = ipct
            scope.integrityColor = ipct >= 75 ? 'var(--bng-add-green-400,#44c078)' : (ipct >= 40 ? 'var(--bng-ter-yellow-400,#e0b020)' : 'var(--bng-add-red-400,#e05248)')
            if (tr.refueling) {
              var rf = tr.refueling
              if (rf.active) {
                scope.refuelTitle = 'Refueling at ' + (rf.stationName || 'Pump')
                scope.refuelReceipt = '+' + Number(rf.litersAdded || 0).toFixed(1) + ' L · -$' + Number(rf.costTotal || 0).toFixed(2)
                scope.refuelBarPct = Math.max(0, Math.min(100, Number(tr.fuelPct || 0)))
              } else if (rf.done) {
                scope.refuelTitle = (rf.overdraftHit ? 'Overdraft Limit · ' : 'Refueled at ') + (rf.stationName || 'Pump')
                scope.refuelReceipt = '+' + Number(rf.litersAdded || 0).toFixed(1) + ' L · -$' + Number(rf.costTotal || 0).toFixed(2)
                scope.refuelBarPct = Math.max(0, Math.min(100, Number(tr.fuelPct || 0)))
              } else {
                scope.refuelTitle = 'Pump Ready · Hold stopped'
                scope.refuelReceipt = Number(rf.holdS || 0).toFixed(1) + '/' + Number(rf.holdTargetS || 1.2).toFixed(1) + 's'
                scope.refuelBarPct = Math.max(0, Math.min(100, Math.round(((rf.holdS || 0) / (rf.holdTargetS || 1.2)) * 100)))
              }
            }
            if (tr.nearestFuelStation) {
              var nfs = tr.nearestFuelStation
              scope.lowFuelText = 'Low Fuel · ' + nfs.name + ' (' + fmtDist(nfs.distM, !!tr.metric) + (nfs.cardinal ? ' ' + nfs.cardinal : '') + ')'
            } else {
              scope.lowFuelText = 'Low Fuel (' + (tr.fuelPct != null ? tr.fuelPct : 0) + '%)'
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
