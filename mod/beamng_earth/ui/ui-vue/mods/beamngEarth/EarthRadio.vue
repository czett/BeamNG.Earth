<template>
  <div class="rd-root" :class="{ compact }">
    <BngCard class="rd-card">
      <BngCardHeading type="line">
        {{ current ? (current.frequency || "FM") : "FM --.-" }}
        <span class="rd-heading-pills">
          <BngPill v-if="current && current.scope" marked :class="scopePillClass(current.scope)">{{ current.scope }}</BngPill>
          <BngPill marked :class="statusPillClass">{{ statusLabel }}</BngPill>
        </span>
      </BngCardHeading>

      <div class="rd-body">
        <div class="rd-station-head">
          <BngIcon :type="icons.music" color="var(--bng-orange-b400)" class="rd-station-icon" />
          <div class="rd-station-copy">
            <div class="rd-station">{{ current ? current.name : "Scanning local stations..." }}</div>
            <div class="rd-sub">
              <span>{{ subLine }}</span>
              <BngPill v-if="st.source === 'live+preset'" class="rd-pill-neutral">Live + Preset</BngPill>
            </div>
          </div>
        </div>

        <div v-if="st.roamNotice" class="rd-roam-note">
          <BngIcon :type="icons.signal04a" color="var(--bng-add-blue-300)" />
          <span>{{ st.roamNotice }}</span>
        </div>

        <div class="rd-controls">
          <BngButton
            :accent="ACCENTS.outlined"
            :icon="icons.prevTrack"
            :disabled="!st.enabled || !stations.length"
            title="Previous station"
            @click="prevStation"
          />
          <BngButton
            class="rd-play-btn"
            :accent="ACCENTS.main"
            :icon-left="st.playing ? icons.pause : icons.play"
            :disabled="!st.enabled || !stations.length"
            @click="togglePlay"
          >{{ st.playing ? "Pause" : "Play" }}</BngButton>
          <BngButton
            :accent="ACCENTS.outlined"
            :icon="icons.nextTrack"
            :disabled="!st.enabled || !stations.length"
            title="Next station"
            @click="nextStation"
          />
          <BngButton
            :accent="ACCENTS.outlined"
            :icon="icons.sync"
            :disabled="!st.enabled"
            title="Refresh local stations"
            @click="refreshStations"
          />
        </div>

        <div class="rd-settings">
          <BngRow class="rd-setting-row">
            <template #label>Show Radio HUD</template>
            <BngSwitch :modelValue="!!st.enabled" @update:modelValue="val => setEnabled(val)" />
          </BngRow>
          <BngRow class="rd-setting-row" :disabled="!st.enabled">
            <template #label>Auto-Roam</template>
            <BngSwitch :modelValue="st.autoRoam !== false" :disabled="!st.enabled" @update:modelValue="val => setAutoRoam(val)" />
          </BngRow>
          <BngRow class="rd-setting-row" :disabled="!st.enabled">
            <template #label>
              <span class="rd-vol-label">
                <BngIcon :type="(st.volume ?? 0.55) <= 0.01 ? icons.soundOff : icons.soundLoud" />
                <span>Volume</span>
                <span class="rd-num rd-vol-pct">{{ Math.round((st.volume ?? 0.55) * 100) }}%</span>
              </span>
            </template>
            <BngSlider
              class="rd-vol-slider"
              :min="0"
              :max="1"
              :step="0.02"
              :disabled="!st.enabled"
              :modelValue="Number(st.volume ?? 0.55)"
              @update:modelValue="val => setVolume(val)"
            />
          </BngRow>
        </div>

        <div v-if="!st.enabled" class="rd-empty">
          Car Radio HUD is hidden by default. Enable "Show Radio HUD" above to scan stations and stream audio.
        </div>
        <div v-else-if="stations.length" class="rd-list">
          <button
            v-for="s in stations"
            :key="s.id"
            type="button"
            class="rd-row"
            :class="{ on: st.currentStationId === s.id }"
            @click="selectStation(s.id)"
          >
            <span class="rd-row-freq rd-num">{{ s.frequency || "FM" }}</span>
            <span class="rd-row-name">{{ s.name }}</span>
            <span class="rd-row-meta">
              <BngIcon v-if="s.scope === 'local'" :type="icons.signal04a" color="var(--bng-add-green-400)" class="rd-local-icon" title="Local station" />
              <span>{{ s.genre }}</span>
            </span>
          </button>
        </div>
        <div v-else class="rd-empty">Load into the BeamNG.Earth world to scan nearby stations.</div>
      </div>
    </BngCard>

    <div v-if="radioError || st.streamError" class="rd-note is-err">{{ radioError || st.streamError }}</div>
    <div v-else class="rd-note">Audio streams play through the BeamNG.Earth Car Radio HUD app while driving.</div>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted } from "vue"
import {
  BngCard, BngCardHeading, BngButton, BngSwitch, BngSlider, BngPill, BngIcon, BngRow, ACCENTS, icons,
} from "@/common/components/base"
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
const statusLabel = computed(() => {
  if (!st.value.enabled) return "OFF"
  return st.value.playing ? (st.value.streamStatus || "BUFFERING") : "PAUSED"
})
const statusPillClass = computed(() => {
  const s = String(statusLabel.value).toLowerCase()
  if (s === "live") return "rd-pill-ok"
  if (s === "buffering") return "rd-pill-warn"
  if (s === "unavailable") return "rd-pill-danger"
  return "rd-pill-neutral"
})
function scopePillClass(scope) {
  if (scope === "local") return "rd-pill-ok"
  if (scope === "regional") return "rd-pill-info"
  return "rd-pill-neutral"
}
const subLine = computed(() => {
  const reg = st.value.regionLabel || st.value.regionCode || ""
  const g = (current.value && current.value.genre) || ""
  if (reg && g) return `${reg} · ${g}`
  return reg || g || "Waiting for location"
})
</script>

<style scoped lang="scss">
.rd-root {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  font-family: "Overpass", var(--fnt-defs);
  color: var(--bng-off-white);
}

.rd-num {
  font-variant-numeric: tabular-nums;
}

.rd-card {
  --bg-opacity: 0.72;
  width: 100%;
}

.rd-heading-pills {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  margin-left: 0.5rem;
  vertical-align: middle;
  font-style: normal;
}

.rd-body {
  display: flex;
  flex-direction: column;
  gap: 0.55rem;
  padding: 0.4rem 0.75rem 0.75rem;
}

.rd-station-head {
  display: flex;
  align-items: center;
  gap: 0.55rem;
  min-width: 0;
}

.rd-station-icon {
  font-size: 1.4rem;
  flex-shrink: 0;
}

.rd-station-copy {
  display: flex;
  flex-direction: column;
  gap: 0.15rem;
  min-width: 0;
  flex: 1 1 auto;
}

.rd-station {
  font-size: 1.05rem;
  font-weight: 700;
  color: var(--bng-off-white);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.rd-sub {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.4rem;
  font-size: 0.82rem;
  color: var(--bng-cool-gray-300);
}

.rd-roam-note {
  display: flex;
  align-items: center;
  gap: 0.4rem;
  padding: 0.35rem 0.55rem;
  border-radius: var(--bng-corners-1);
  background: rgba(var(--bng-ter-blue-gray-900-rgb), 0.7);
  font-size: 0.82rem;
  color: var(--bng-add-blue-200);
}

.rd-controls {
  display: flex;
  align-items: center;
  gap: 0.35rem;
}

.rd-play-btn {
  flex: 1 1 auto;
  max-width: none;
}

.rd-settings {
  display: flex;
  flex-direction: column;
  gap: 0.2rem;
}

.rd-setting-row {
  padding: 0.15rem 0.25rem;
}

.rd-vol-label {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
}

.rd-vol-pct {
  font-size: 0.82rem;
  color: var(--bng-cool-gray-300);
}

.rd-vol-slider {
  min-width: 7rem;
}

.rd-list {
  display: flex;
  flex-direction: column;
  gap: 0.2rem;
  max-height: 12rem;
  overflow-y: auto;
  padding-top: 0.35rem;
  border-top: 1px solid rgba(var(--bng-cool-gray-600-rgb), 0.35);
}

.rd-row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  width: 100%;
  padding: 0.35rem 0.5rem;
  border: none;
  border-radius: var(--bng-corners-1);
  background: rgba(var(--bng-ter-blue-gray-900-rgb), 0.55);
  color: var(--bng-cool-gray-100);
  font-family: inherit;
  font-size: 0.85rem;
  text-align: left;
  cursor: pointer;

  &:hover {
    background: rgba(var(--bng-ter-blue-gray-800-rgb), 0.85);
    color: var(--bng-off-white);
  }

  &.on {
    background: rgba(var(--bng-orange-600-rgb), 0.28);
    box-shadow: inset 0.2rem 0 0 var(--bng-orange-b400);
    color: var(--bng-off-white);
    font-weight: 700;
  }
}

.rd-row-freq {
  width: 4.1rem;
  flex-shrink: 0;
  font-weight: 700;
  font-size: 0.8rem;
  color: var(--bng-orange-300);
}

.rd-row-name {
  flex: 1 1 auto;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.rd-row-meta {
  display: inline-flex;
  align-items: center;
  gap: 0.3rem;
  font-size: 0.78rem;
  color: var(--bng-cool-gray-300);
  white-space: nowrap;
  flex-shrink: 0;
}

.rd-local-icon {
  font-size: 0.9rem;
}

.rd-pill-ok {
  --bng-pill-marked-background-color: var(--bng-add-green-700);
  --bng-pill-text-color: var(--bng-off-white);
  font-size: 0.72rem;
  padding: 0.12em 0.55em;
  text-transform: uppercase;
}

.rd-pill-info {
  --bng-pill-marked-background-color: var(--bng-add-blue-700);
  --bng-pill-text-color: var(--bng-off-white);
  font-size: 0.72rem;
  padding: 0.12em 0.55em;
  text-transform: uppercase;
}

.rd-pill-warn {
  --bng-pill-marked-background-color: var(--bng-ter-yellow-700);
  --bng-pill-text-color: var(--bng-off-white);
  font-size: 0.72rem;
  padding: 0.12em 0.55em;
  text-transform: uppercase;
}

.rd-pill-danger {
  --bng-pill-marked-background-color: var(--bng-add-red-700);
  --bng-pill-text-color: var(--bng-off-white);
  font-size: 0.72rem;
  padding: 0.12em 0.55em;
  text-transform: uppercase;
}

.rd-pill-neutral {
  --bng-pill-marked-background-color: var(--bng-ter-blue-gray-800);
  --bng-pill-default-border-color: var(--bng-ter-blue-gray-600);
  --bng-pill-text-color: var(--bng-cool-gray-200);
  font-size: 0.72rem;
  padding: 0.12em 0.55em;
  text-transform: uppercase;
}

.rd-empty {
  padding: 0.45rem 0.55rem;
  border-radius: var(--bng-corners-1);
  background: rgba(var(--bng-ter-blue-gray-900-rgb), 0.55);
  font-size: 0.82rem;
  color: var(--bng-cool-gray-300);
}

.rd-note {
  font-size: 0.82rem;
  color: var(--bng-cool-gray-300);

  &.is-err {
    color: var(--bng-add-red-300);
  }
}

.rd-root.compact {
  .rd-body {
    padding: 0.35rem 0.55rem 0.55rem;
    gap: 0.4rem;
  }

  .rd-vol-slider {
    min-width: 5.5rem;
  }
}
</style>
