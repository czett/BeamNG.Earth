<template>
  <div class="rd-root" :class="{ compact }">
    <div class="rd-card">
      <div class="rd-head">
        <div class="rd-freq-wrap">
          <span class="rd-freq rd-num">{{ current ? (current.frequency || "FM") : "FM --.-" }}</span>
          <span v-if="current && current.scope" class="rd-scope" :class="'scope-' + current.scope">{{ current.scope }}</span>
        </div>
        <span class="rd-status" :class="'st-' + statusLower">{{ statusLabel }}</span>
      </div>

      <div class="rd-station">{{ current ? current.name : "Scanning local stations..." }}</div>
      <div class="rd-sub">
        <span>{{ subLine }}</span>
        <span v-if="st.source === 'live+preset'" class="rd-live-src">Live + Preset</span>
      </div>

      <div v-if="st.roamNotice" class="rd-roam-note">{{ st.roamNotice }}</div>

      <div class="rd-controls">
        <button class="rd-btn" @click="prevStation" :disabled="!stations.length" title="Previous station">&#9664;</button>
        <button class="rd-btn primary" @click="togglePlay" :disabled="!stations.length">{{ st.playing ? "Pause" : "Play" }}</button>
        <button class="rd-btn" @click="nextStation" :disabled="!stations.length" title="Next station">&#9654;</button>
        <button class="rd-btn" @click="refreshStations" title="Refresh local stations">&#8635;</button>
      </div>

      <div class="rd-toggles">
        <label class="rd-roam-label" title="Show the Car Radio HUD widget and scan local stations while driving (opt-in)">
          <input type="checkbox" :checked="!!st.enabled" @change="e => setEnabled(e.target.checked)" />
          <span>Show Radio HUD</span>
        </label>
        <label class="rd-roam-label" title="Automatically switch to a matching-genre station when leaving a local station's area">
          <input type="checkbox" :checked="st.autoRoam !== false" :disabled="!st.enabled" @change="e => setAutoRoam(e.target.checked)" />
          <span>Auto-Roam</span>
        </label>
        <div class="rd-vol-wrap">
          <span class="rd-vol-k rd-num">{{ Math.round((st.volume ?? 0.55) * 100) }}%</span>
          <input
            type="range"
            min="0"
            max="1"
            step="0.02"
            :value="st.volume ?? 0.55"
            :disabled="!st.enabled"
            @input="e => setVolume(e.target.value)"
            class="rd-vol"
          />
        </div>
      </div>

      <div v-if="!st.enabled" class="rd-empty">Car Radio HUD is hidden by default. Enable "Show Radio HUD" above to scan stations and stream audio.</div>
      <div v-else-if="stations.length" class="rd-list">
        <button
          v-for="s in stations"
          :key="s.id"
          class="rd-row"
          :class="{ on: st.currentStationId === s.id }"
          @click="selectStation(s.id)"
        >
          <span class="rd-row-freq rd-num">{{ s.frequency || "FM" }}</span>
          <span class="rd-row-name">{{ s.name }}</span>
          <span class="rd-row-meta">
            <span v-if="s.scope === 'local'" class="rd-dot" title="Local station"></span>
            <span>{{ s.genre }}</span>
          </span>
        </button>
      </div>
      <div v-else class="rd-empty">Load into the BeamNG.Earth world to scan nearby stations.</div>
    </div>

    <div v-if="radioError || st.streamError" class="rd-note is-err">{{ radioError || st.streamError }}</div>
    <div v-else class="rd-note">Audio streams play through the BeamNG.Earth Car Radio HUD app while driving.</div>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted } from "vue"
import {
  radioState, radioError, toArray, start, stop,
  togglePlay, nextStation, prevStation, selectStation, setVolume, setAutoRoam, setEnabled, refreshStations,
} from "./earthRadioStore.js"

const props = defineProps({
  compact: { type: Boolean, default: false },
  externalPoll: { type: Boolean, default: false },
})

onMounted(() => { if (!props.externalPoll) start() })
onUnmounted(() => { if (!props.externalPoll) stop() })

const st = computed(() => radioState.value || {})
const stations = computed(() => toArray(st.value.stations))
const current = computed(() => st.value.currentStation || null)
const statusLabel = computed(() => st.value.playing ? (st.value.streamStatus || "BUFFERING") : "PAUSED")
const statusLower = computed(() => String(statusLabel.value).toLowerCase())
const subLine = computed(() => {
  const reg = st.value.regionLabel || st.value.regionCode || ""
  const g = (current.value && current.value.genre) || ""
  if (reg && g) return `${reg} · ${g}`
  return reg || g || "Waiting for location"
})
</script>

<style scoped>
.rd-root {
  display: flex;
  flex-direction: column;
  gap: 8px;
  font-size: 13px;
  color: #edf1f6;
}
.rd-num {
  font-variant-numeric: tabular-nums;
}
.rd-card {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 11px;
  border-radius: 6px;
  background: rgba(16, 20, 26, 0.90);
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-left: 3px solid #38bdf8;
}
.rd-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}
.rd-freq-wrap {
  display: flex;
  align-items: center;
  gap: 6px;
}
.rd-freq {
  font-size: 13px;
  font-weight: 700;
  color: #38bdf8;
}
.rd-scope {
  padding: 1px 6px;
  border-radius: 3px;
  font-size: 10px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  border: 1px solid rgba(255, 255, 255, 0.16);
  background: rgba(255, 255, 255, 0.08);
  color: #b8c4d0;
}
.rd-scope.scope-local {
  background: rgba(61, 220, 132, 0.16);
  border-color: rgba(61, 220, 132, 0.40);
  color: #6ae696;
}
.rd-scope.scope-regional {
  background: rgba(56, 189, 248, 0.16);
  border-color: rgba(56, 189, 248, 0.40);
  color: #7dd3fc;
}
.rd-status {
  padding: 1px 6px;
  border-radius: 3px;
  font-size: 10px;
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  background: rgba(255, 255, 255, 0.08);
  color: #9aa6b2;
}
.rd-status.st-live { background: rgba(61, 220, 132, 0.18); color: #6ae696; }
.rd-status.st-buffering { background: rgba(245, 158, 11, 0.18); color: #fbbf24; }
.rd-status.st-unavailable { background: rgba(248, 113, 113, 0.20); color: #fca5a5; }

.rd-station {
  font-size: 15px;
  font-weight: 600;
  color: #fff;
}
.rd-sub {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 6px;
  font-size: 11.5px;
  color: #93a0ad;
}
.rd-live-src {
  padding: 1px 5px;
  border-radius: 3px;
  font-size: 10px;
  background: rgba(56, 189, 248, 0.14);
  color: #7dd3fc;
}
.rd-roam-note {
  font-size: 11px;
  color: #7dd3fc;
}
.rd-controls {
  display: flex;
  gap: 6px;
}
.rd-btn {
  padding: 6px 10px;
  border-radius: 5px;
  border: 1px solid rgba(255, 255, 255, 0.14);
  background: rgba(255, 255, 255, 0.07);
  color: #e6ecf2;
  font: inherit;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
}
.rd-btn:hover:not(:disabled) {
  background: rgba(255, 255, 255, 0.13);
}
.rd-btn.primary {
  flex: 1;
  background: #ff6600;
  border-color: #ff7a1f;
  color: #fff;
  font-weight: 700;
}
.rd-btn.primary:hover:not(:disabled) { background: #ff791f; }
.rd-btn:disabled { opacity: 0.45; cursor: default; }

.rd-toggles {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  padding-top: 4px;
  border-top: 1px solid rgba(255, 255, 255, 0.08);
}
.rd-roam-label {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  color: #cdd6df;
  cursor: pointer;
}
.rd-vol-wrap {
  display: flex;
  align-items: center;
  gap: 6px;
  flex: 1;
  max-width: 170px;
}
.rd-vol-k {
  font-size: 11px;
  color: #93a0ad;
  min-width: 32px;
  text-align: right;
}
.rd-vol {
  flex: 1;
  accent-color: #ff6600;
  cursor: pointer;
}

.rd-list {
  display: flex;
  flex-direction: column;
  gap: 4px;
  max-height: 240px;
  overflow-y: auto;
  padding-top: 6px;
  border-top: 1px solid rgba(255, 255, 255, 0.08);
}
.compact .rd-list { max-height: 185px; }
.rd-row {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 5px 8px;
  border-radius: 4px;
  border: 1px solid rgba(255, 255, 255, 0.07);
  background: rgba(0, 0, 0, 0.28);
  color: #dce4ec;
  font: inherit;
  font-size: 12px;
  text-align: left;
  cursor: pointer;
}
.rd-row:hover { background: rgba(255, 255, 255, 0.09); }
.rd-row.on {
  border-color: #ff6600;
  background: rgba(255, 102, 0, 0.18);
  color: #ffd6b5;
  font-weight: 600;
}
.rd-row-freq {
  font-size: 11px;
  color: #7dd3fc;
  min-width: 58px;
}
.rd-row-name {
  flex: 1;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.rd-row-meta {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  font-size: 10.5px;
  color: #93a0ad;
  white-space: nowrap;
}
.rd-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: #3ddc84;
}
.rd-empty, .rd-note {
  font-size: 11.5px;
  color: #93a0ad;
}
.rd-note.is-err { color: #fca5a5; }
</style>
