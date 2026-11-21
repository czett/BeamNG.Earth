// BeamNG.Earth Location-Aware Car Radio HUD app (lua/ge/extensions/beamngEarth/hudapps.lua + locationRadio.lua).
// Hosts the persistent HTML5 <audio> player for live MP3/AAC streams with automatic fallback.
angular.module('beamng.apps')
.directive('beamngEarthRadio', [function () {
  var CARD = 'background:rgba(16,20,26,0.90);color:#edf1f6;border:1px solid rgba(255,255,255,0.12);' +
    'border-left:3px solid #38bdf8;border-radius:6px;padding:9px 11px;font-size:12.5px;line-height:1.3;' +
    'box-shadow:0 4px 16px rgba(0,0,0,0.48);'
  var BTN = 'background:rgba(255,255,255,0.07);color:#e4ebf2;border:1px solid rgba(255,255,255,0.16);' +
    'border-radius:4px;padding:3px 8px;font-size:11px;font-weight:600;cursor:pointer;'
  var PLAY_BTN = 'background:#ff6600;color:#fff;border:1px solid #ff7a1f;' +
    'border-radius:4px;padding:3px 11px;font-size:11px;font-weight:700;cursor:pointer;'
  var NUM = 'font-variant-numeric:tabular-nums;'

  return {
    template:
      '<div class="bngApp" style="width:100%;height:100%;background:transparent;box-shadow:none;overflow:visible;">' +
        '<div ng-if="radio && radio.enabled && !hidden" style="' + CARD + '">' +
          '<div style="display:flex;justify-content:space-between;align-items:center;gap:6px;margin-bottom:4px;">' +
            '<div style="display:flex;align-items:center;gap:5px;min-width:0;">' +
              '<span style="font-weight:700;font-size:12px;color:#38bdf8;white-space:nowrap;' + NUM + '">{{ freqText }}</span>' +
              '<span ng-if="scopeLabel" ng-style="scopeStyle" style="padding:1px 5px;border-radius:3px;border:1px solid transparent;font-weight:700;font-size:9.5px;letter-spacing:0.05em;text-transform:uppercase;white-space:nowrap;">{{ scopeLabel }}</span>' +
            '</div>' +
            '<span ng-style="statusStyle" style="padding:1px 6px;border-radius:3px;font-weight:700;font-size:9.5px;letter-spacing:0.04em;text-transform:uppercase;white-space:nowrap;">{{ statusLabel }}</span>' +
          '</div>' +

          '<div style="font-weight:600;font-size:13.5px;color:#fff;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ stationName }}</div>' +
          '<div style="display:flex;justify-content:space-between;align-items:center;gap:6px;margin-top:2px;font-size:11px;color:#93a0ad;">' +
            '<span style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ subLine }}</span>' +
          '</div>' +
          '<div ng-if="radio.roamNotice" style="margin-top:3px;font-size:10.5px;color:#7dd3fc;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">{{ radio.roamNotice }}</div>' +

          '<div style="display:flex;align-items:center;gap:5px;margin-top:7px;">' +
            '<button ng-click="prev()" title="Previous station" style="' + BTN + '">&#9664;</button>' +
            '<button ng-click="togglePlay()" style="' + PLAY_BTN + '">{{ radio.playing ? "Pause" : "Play" }}</button>' +
            '<button ng-click="next()" title="Next station" style="' + BTN + '">&#9654;</button>' +
            '<button ng-click="toggleRoam()" ng-style="roamBtnStyle" title="Auto-tune when leaving local station area" style="' + BTN + 'margin-left:2px;">Roam</button>' +
            '<input type="range" min="0" max="1" step="0.02" ng-model="volUi" ng-change="onVolInput()" ' +
              'style="flex:1;min-width:44px;accent-color:#ff6600;cursor:pointer;height:4px;margin-left:4px;" title="Volume" />' +
          '</div>' +

          '<div ng-if="presets.length" style="display:flex;gap:4px;margin-top:6px;overflow-x:auto;padding-bottom:1px;">' +
            '<button ng-repeat="st in presets track by st.id" ng-click="select(st.id)" ' +
              'ng-style="presetStyle(st)" ' +
              'style="padding:2px 6px;border-radius:3px;border:1px solid rgba(255,255,255,0.14);font-size:10.5px;white-space:nowrap;cursor:pointer;flex-shrink:0;">' +
              '<span ng-if="st.scope === \'local\'" style="display:inline-block;width:5px;height:5px;border-radius:50%;background:#3ddc84;margin-right:4px;vertical-align:middle;"></span>' +
              '{{ st.name }}' +
            '</button>' +
          '</div>' +
        '</div>' +
      '</div>',
    replace: true,
    link: function (scope, element) {
      'use strict'
      scope.radio = null
      scope.hidden = false
      scope.volUi = 0.55
      scope.freqText = 'FM --.-'
      scope.stationName = 'Scanning local stations...'
      scope.subLine = 'Waiting for location'
      scope.scopeLabel = ''
      scope.scopeStyle = {}
      scope.statusLabel = 'STOPPED'
      scope.statusStyle = { background: 'rgba(255,255,255,0.08)', color: '#9aa6b2' }
      scope.roamBtnStyle = {}
      scope.presets = []

      var audio = new Audio()
      audio.preload = 'none'
      var activeStationId = ''
      var activeUrl = ''
      var candidateUrls = []
      var candidateIdx = 0
      var failedStations = 0
      var ignoreNextVol = false
      var playToken = 0

      var MEDIA_ERR_NAMES = {
        1: 'MEDIA_ERR_ABORTED',
        2: 'MEDIA_ERR_NETWORK',
        3: 'MEDIA_ERR_DECODE',
        4: 'MEDIA_ERR_SRC_NOT_SUPPORTED'
      }

      var unclipped = false
      function unclip () {
        if (unclipped) return
        var el = element && element[0]
        var host = el && el.closest ? el.closest('.ui-app-host') : null
        if (host) { host.style.overflow = 'visible'; unclipped = true }
      }

      function reportStatus (status, errText) {
        if (!activeStationId) return
        bngApi.engineLua(
          'if beamngEarth_locationRadio then beamngEarth_locationRadio.reportStreamStatus(' +
          JSON.stringify(status) + ', ' + JSON.stringify(activeStationId) + ', ' +
          JSON.stringify(errText || '') + ') end'
        )
      }

      function buildCandidates (st) {
        var urls = []
        if (st && st.streamUrl) urls.push(st.streamUrl)
        if (st && Array.isArray(st.fallbackUrls)) {
          for (var i = 0; i < st.fallbackUrls.length; i++) {
            if (st.fallbackUrls[i] && urls.indexOf(st.fallbackUrls[i]) < 0) urls.push(st.fallbackUrls[i])
          }
        }
        return urls
      }

      function handleStreamFailure (code, detail) {
        if (!scope.radio || !scope.radio.playing) return
        candidateIdx += 1
        if (candidateIdx < candidateUrls.length) {
          playCandidate(candidateUrls[candidateIdx])
          return
        }
        failedStations += 1
        var msg = detail || (code ? ('Stream unavailable (code ' + code + ')') : 'Stream unavailable')
        reportStatus('UNAVAILABLE', msg)
        var list = scope.presets || []
        if (list.length > 1 && failedStations < list.length) {
          bngApi.engineLua('if beamngEarth_locationRadio then beamngEarth_locationRadio.nextStation() end')
        }
      }

      function playCandidate (url) {
        if (!url) return
        playToken += 1
        var token = playToken
        activeUrl = url
        try { audio.pause() } catch (e) {}
        audio.src = url
        audio.volume = Math.max(0, Math.min(1, Number(scope.radio && scope.radio.volume != null ? scope.radio.volume : scope.volUi)))
        try { audio.load() } catch (e) {}
        reportStatus('BUFFERING', '')
        var p = audio.play()
        if (p && typeof p.catch === 'function') {
          p.catch(function (err) {
            if (token !== playToken || !activeUrl || !scope.radio || !scope.radio.playing) return
            if (err && err.name === 'AbortError') return
            var errCode = (audio.error && audio.error.code) || 0
            console.warn(
              '[BeamNGEarthRadio] audio.play() failed name=' + (err && err.name || 'Error') +
              ' code=' + errCode +
              ' msg=' + (err && err.message || '') +
              ' url=' + url
            )
            // If no media error event fires for NotSupportedError/NotAllowedError, advance cleanly
            if (err && err.name === 'NotSupportedError' && !audio.error) {
              handleStreamFailure(4, 'NotSupportedError')
            }
          })
        }
      }

      function stopAudio () {
        playToken += 1
        var hadUrl = !!activeUrl
        activeUrl = ''
        if (!audio.paused || hadUrl) {
          try { audio.pause() } catch (e) {}
          try { audio.removeAttribute('src'); audio.load() } catch (e) {}
        }
      }

      audio.addEventListener('playing', function () {
        if (!activeUrl) return
        failedStations = 0
        reportStatus('LIVE', '')
      })
      audio.addEventListener('waiting', function () {
        if (activeUrl && scope.radio && scope.radio.playing) reportStatus('BUFFERING', '')
      })
      audio.addEventListener('error', function () {
        if (!activeUrl || !scope.radio || !scope.radio.playing) return
        var err = audio.error
        var code = err ? err.code : 0
        var codeName = MEDIA_ERR_NAMES[code] || 'UNKNOWN'
        var errMsg = (err && err.message) ? err.message : ''
        console.warn(
          '[BeamNGEarthRadio] audio error code=' + code + ' (' + codeName + ')' +
          (errMsg ? ' msg=' + errMsg : '') +
          ' url=' + activeUrl
        )
        handleStreamFailure(code, code ? (codeName + ' (' + code + ')') : 'Stream unavailable')
      })

      function syncAudio (r) {
        if (!r || !r.enabled || !r.playing || !r.currentStation || !r.currentStation.streamUrl) {
          stopAudio()
          activeStationId = (r && r.currentStation && r.currentStation.id) || ''
          return
        }
        audio.volume = Math.max(0, Math.min(1, Number(r.volume != null ? r.volume : 0.55)))
        var st = r.currentStation
        var primaryChanged = candidateUrls.length > 0 && st.streamUrl !== candidateUrls[0]
        if (st.id !== activeStationId || !activeUrl || primaryChanged) {
          activeStationId = st.id
          candidateUrls = buildCandidates(st)
          candidateIdx = 0
          playCandidate(candidateUrls[0])
        }
      }

      function toArr (v) {
        if (Array.isArray(v)) return v
        if (v && typeof v === 'object') {
          return Object.keys(v).sort(function (a, b) { return Number(a) - Number(b) }).map(function (k) { return v[k] })
        }
        return []
      }

      var hello = function (on) {
        bngApi.engineLua('if beamngEarth_core and beamngEarth_core.hudApp then beamngEarth_core.hudApp("radio", ' + on + ') end')
      }

      scope.togglePlay = function () {
        failedStations = 0
        bngApi.engineLua('if beamngEarth_locationRadio then beamngEarth_locationRadio.togglePlay() end')
      }
      scope.next = function () {
        failedStations = 0
        bngApi.engineLua('if beamngEarth_locationRadio then beamngEarth_locationRadio.nextStation() end')
      }
      scope.prev = function () {
        failedStations = 0
        bngApi.engineLua('if beamngEarth_locationRadio then beamngEarth_locationRadio.prevStation() end')
      }
      scope.select = function (id) {
        failedStations = 0
        bngApi.engineLua('if beamngEarth_locationRadio then beamngEarth_locationRadio.selectStation(' + JSON.stringify(id) + ') end')
      }
      scope.toggleRoam = function () {
        var nextVal = !(scope.radio && scope.radio.autoRoam)
        bngApi.engineLua('if beamngEarth_locationRadio then beamngEarth_locationRadio.setAutoRoam(' + nextVal + ') end')
      }
      scope.onVolInput = function () {
        if (ignoreNextVol) { ignoreNextVol = false; return }
        var v = Math.max(0, Math.min(1, Number(scope.volUi) || 0))
        audio.volume = v
        bngApi.engineLua('if beamngEarth_locationRadio then beamngEarth_locationRadio.setVolume(' + v + ') end')
      }
      scope.presetStyle = function (st) {
        var on = scope.radio && scope.radio.currentStationId === st.id
        return on
          ? { background: 'rgba(255,102,0,0.22)', borderColor: '#ff6600', color: '#ffd6b5', fontWeight: '700' }
          : { background: 'rgba(255,255,255,0.06)', borderColor: 'rgba(255,255,255,0.14)', color: '#cdd6df', fontWeight: '500' }
      }

      scope.$on('BeamNGEarthHud', function (event, data) {
        scope.$evalAsync(function () {
          var r = (data && data.radio) || null
          scope.radio = r
          scope.hidden = !!(data && data.hidden)
          if (r) {
            if (r.volume != null && Math.abs(Number(scope.volUi) - Number(r.volume)) > 0.02) {
              ignoreNextVol = true
              scope.volUi = Number(r.volume)
            }
            var st = r.currentStation || null
            scope.freqText = (st && st.frequency) ? st.frequency : 'FM --.-'
            scope.stationName = (st && st.name) ? st.name : 'Scanning local stations...'
            var reg = r.regionLabel || r.regionCode || ''
            var genre = (st && st.genre) ? st.genre : ''
            scope.subLine = (reg && genre) ? (reg + ' · ' + genre) : (reg || genre || 'Ready')

            var sc = (st && st.scope) || ''
            if (sc === 'local') {
              scope.scopeLabel = 'LOCAL'
              scope.scopeStyle = { background: 'rgba(61,220,132,0.16)', borderColor: 'rgba(61,220,132,0.40)', color: '#6ae696' }
            } else if (sc === 'regional') {
              scope.scopeLabel = 'REGIONAL'
              scope.scopeStyle = { background: 'rgba(56,189,248,0.16)', borderColor: 'rgba(56,189,248,0.40)', color: '#7dd3fc' }
            } else if (sc) {
              scope.scopeLabel = sc.toUpperCase()
              scope.scopeStyle = { background: 'rgba(255,255,255,0.08)', borderColor: 'rgba(255,255,255,0.16)', color: '#b8c4d0' }
            } else {
              scope.scopeLabel = ''
            }

            var ss = r.playing ? (r.streamStatus || 'BUFFERING') : 'PAUSED'
            scope.statusLabel = ss
            if (ss === 'LIVE') {
              scope.statusStyle = { background: 'rgba(61,220,132,0.18)', color: '#6ae696' }
            } else if (ss === 'BUFFERING') {
              scope.statusStyle = { background: 'rgba(245,158,11,0.18)', color: '#fbbf24' }
            } else if (ss === 'UNAVAILABLE') {
              scope.statusStyle = { background: 'rgba(248,113,113,0.20)', color: '#fca5a5' }
            } else {
              scope.statusStyle = { background: 'rgba(255,255,255,0.08)', color: '#9aa6b2' }
            }

            scope.roamBtnStyle = r.autoRoam
              ? { background: 'rgba(56,189,248,0.18)', borderColor: 'rgba(56,189,248,0.45)', color: '#7dd3fc' }
              : { background: 'rgba(255,255,255,0.06)', borderColor: 'rgba(255,255,255,0.14)', color: '#9aa6b2' }

            scope.presets = toArr(r.stations)
            syncAudio(r)
          } else {
            stopAudio()
          }
          unclip()
        })
      })

      hello(true)
      var again = setInterval(function () { hello(true) }, 3000)
      scope.$on('$destroy', function () {
        clearInterval(again)
        stopAudio()
        hello(false)
      })
    }
  }
}]);
