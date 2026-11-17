<template>
  <div class="tm-root" :class="{ compact }">
    <div v-if="!ready" class="tm-note is-warn">
      Load into the BeamNG.Earth world to start a transport job.
    </div>

    <!-- Active Job -->
    <template v-if="active">
      <div class="tm-card" :class="'mode-border-' + active.mode">
        <div class="tm-head">
          <div class="tm-head-badges">
            <span class="tm-badge" :class="'mode-' + active.mode">{{ modeLabel(active.mode) }}</span>
            <span v-if="currentStop" class="tm-type-pill" :class="'type-' + (currentStop.stopType || 'kerbside')">
              {{ stopTypeLabel(currentStop.stopType) }}
            </span>
          </div>
          <span class="tm-stop-count tm-num">Stop {{ active.stopIndex }}/{{ active.stopCount }}</span>
        </div>
        <div v-if="active.title" class="tm-title">{{ active.title }}</div>
        <div class="tm-current">
          <div class="tm-stop-header">
            <div class="tm-stop-name">{{ currentStop ? currentStop.name : "Next stop" }}</div>
            <span v-if="currentStop && currentStop.kind" class="tm-kind-tag">{{ stopKindLabel(currentStop.kind) }}</span>
          </div>
          <div v-if="currentStop && currentStop.address" class="tm-stop-addr">{{ currentStop.address }}</div>
          <div class="tm-metrics">
            <div class="tm-metric">
              <span class="tm-metric-k">To stop</span>
              <b class="tm-num">{{ formatDist(active.distM, metric) }}</b>
            </div>
            <div v-if="active.etaS != null" class="tm-metric">
              <span class="tm-metric-k">ETA</span>
              <b class="tm-num">{{ formatDur(active.etaS) }}</b>
            </div>
            <div class="tm-metric">
              <span class="tm-metric-k">Score</span>
              <b class="tm-num">{{ active.score }}/100</b>
            </div>
          </div>
          <div v-if="active.dwellFrac > 0" class="tm-dwell" :class="{ fallback: active.dwellMode === 'fallback' }">
            <div class="tm-dwell-row">
              <span>{{ dwellLabel }}</span>
              <span class="tm-num">{{ dwellTimerText }}</span>
            </div>
            <div class="tm-bar">
              <span
                class="tm-bar-fill"
                :class="active.dwellMode === 'fallback' ? 'fallback' : 'dwell'"
                :style="{ width: Math.round(active.dwellFrac * 100) + '%' }"
              ></span>
            </div>
          </div>
          <div v-else-if="active.distM != null && active.distM <= 35" class="tm-bay-hint">
            {{ currentStop && currentStop.stopType === 'loading_bay' ? 'Pull into the loading bay and stop' : 'Pull up to the kerbside bay and stop' }}
          </div>
        </div>
        <div class="tm-actions">
          <button class="tm-btn" @click="skipStop">Skip Stop</button>
          <button class="tm-btn danger" @click="cancelJob">Cancel Job</button>
        </div>
        <div v-if="stops.length" class="tm-stops">
          <div
            v-for="(s, idx) in stops"
            :key="idx"
            class="tm-stop-row"
            :class="{ done: idx + 1 < active.stopIndex, current: idx + 1 === active.stopIndex }"
            @click="$emit('focus-stop', s)"
          >
            <span class="tm-stop-num tm-num">{{ idx + 1 < active.stopIndex ? '✓' : idx + 1 }}</span>
            <span class="tm-stop-label">{{ s.name }}</span>
            <span class="tm-stop-kind">{{ s.stopType === 'loading_bay' ? 'Bay' : stopKindLabel(s.kind) }}</span>
          </div>
        </div>
      </div>
    </template>

    <!-- Pending request -->
    <template v-else-if="pending || busy">
      <div class="tm-card">
        <div class="tm-head">
          <span class="tm-badge" :class="'mode-' + ((pending && pending.mode) || selectedMode)">{{ modeLabel((pending && pending.mode) || selectedMode) }}</span>
          <span class="tm-stop-count">Locating bays</span>
        </div>
        <div class="tm-title">Generating {{ modeLabel((pending && pending.mode) || selectedMode) }} route...</div>
        <div class="tm-note">Finding clear loading bays and kerbside stops nearby.</div>
        <div class="tm-actions">
          <button class="tm-btn danger" @click="cancelJob">Cancel</button>
        </div>
      </div>
    </template>

    <!-- Completion Summary -->
    <template v-else-if="summary">
      <div class="tm-card" :class="'mode-border-' + summary.mode">
        <div class="tm-head">
          <span class="tm-badge" :class="'mode-' + summary.mode">{{ modeLabel(summary.mode) }}</span>
          <span class="tm-stop-count is-complete">Job Complete</span>
        </div>
        <div v-if="summary.title" class="tm-title">{{ summary.title }}</div>
        <div class="tm-summary-grid">
          <div><span>Stops</span><b class="tm-num">{{ summary.stopsCompleted }}/{{ summary.stopCount }}</b></div>
          <div><span>Distance</span><b class="tm-num">{{ formatDist(summary.drivenM, metric) }}</b></div>
          <div><span>Time</span><b class="tm-num">{{ formatDur(summary.elapsedS) }}</b></div>
          <div><span>Smoothness</span><b class="tm-num">{{ summary.smoothnessPct }}%</b></div>
          <div><span>Collisions</span><b class="tm-num">{{ summary.collisions }}</b></div>
          <div class="is-score"><span>Score</span><b class="tm-num">{{ summary.score }}/100</b></div>
        </div>
        <div class="tm-actions">
          <button class="tm-btn primary" @click="dismissSummary">New Job</button>
        </div>
      </div>
    </template>

    <!-- Idle Job Picker -->
    <template v-if="!active && !pending && !busy && !summary">
      <div class="tm-section-label">Mode</div>
      <div class="tm-seg">
        <button
          v-for="m in TRANSPORT_MODES"
          :key="m.id"
          class="tm-btn"
          :class="{ on: selectedMode === m.id }"
          @click="setMode(m.id)"
        >{{ m.label }}</button>
      </div>
      <div class="tm-mode-desc">{{ activeModeDesc }}</div>

      <div class="tm-section-label">Scale / Distance</div>
      <div class="tm-tiers">
        <button
          v-for="t in currentTiers"
          :key="t.id"
          class="tm-tier-btn"
          :class="{ on: selectedTier === t.id }"
          @click="setTier(t.id)"
        >{{ t.label }}</button>
      </div>

      <div class="tm-actions">
        <button class="tm-btn primary" :disabled="!ready" @click="startJob">Start Job</button>
      </div>
    </template>

    <div v-if="errText" class="tm-note is-error">{{ errText }}</div>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted } from "vue"
import {
  TRANSPORT_MODES, selectedMode, selectedTier, currentTiers,
  transportState, busy, actionError,
  setMode, setTier, startJob, skipStop, cancelJob, dismissSummary,
  modeLabel, stopTypeLabel, stopKindLabel, formatDist, formatDur, toArray, start, stop,
} from "./earthTransportStore.js"

const props = defineProps({
  compact: { type: Boolean, default: false },
  externalPoll: { type: Boolean, default: false },
})
defineEmits(["focus-stop"])

onMounted(() => { if (!props.externalPoll) start() })
onUnmounted(() => { if (!props.externalPoll) stop() })

const st = computed(() => transportState.value || {})
const ready = computed(() => st.value.ready === true)
const active = computed(() => st.value.active || null)
const pending = computed(() => st.value.pending || null)
const summary = computed(() => st.value.summary || null)
const metric = computed(() => st.value.metric === true)
const stops = computed(() => active.value ? toArray(active.value.stops) : [])
const currentStop = computed(() => {
  if (!active.value || !stops.value.length) return null
  return stops.value[(active.value.stopIndex || 1) - 1] || null
})
const dwellLabel = computed(() => {
  if (!active.value) return "Hold in bay"
  return active.value.dwellMode === "fallback" ? "Kerbside fallback" : "Hold in bay"
})
const dwellTimerText = computed(() => {
  if (!active.value) return ""
  const target = Number(active.value.dwellTargetS || (active.value.dwellMode === "fallback" ? 5.0 : 2.5))
  const cur = active.value.dwellS != null ? Number(active.value.dwellS) : Number(active.value.dwellFrac || 0) * target
  return `${cur.toFixed(1)} / ${target.toFixed(1)} s`
})
const activeModeDesc = computed(() => {
  const m = TRANSPORT_MODES.find(x => x.id === selectedMode.value)
  return m ? m.desc : ""
})
const errText = computed(() => actionError.value || st.value.error || "")
</script>

<style scoped>
.tm-root {
  display: flex;
  flex-direction: column;
  gap: 8px;
  font-size: 13px;
  color: #eef1f4;
}
.tm-num {
  font-variant-numeric: tabular-nums;
}
.tm-section-label {
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: #93a0ad;
  margin-top: 2px;
}
.tm-mode-desc {
  font-size: 12px;
  color: #b8c2cc;
  line-height: 1.4;
}
.tm-seg {
  display: flex;
  gap: 6px;
}
.tm-seg .tm-btn { flex: 1; }
.tm-tiers {
  display: flex;
  flex-direction: column;
  gap: 5px;
}
.tm-btn, .tm-tier-btn {
  padding: 6px 10px;
  border-radius: 5px;
  border: 1px solid rgba(255, 255, 255, 0.22);
  background: rgba(255, 255, 255, 0.06);
  color: #eef1f4;
  font: inherit;
  font-size: 13px;
  cursor: pointer;
  text-align: center;
  transition: background 0.12s ease, border-color 0.12s ease;
}
.tm-tier-btn { text-align: left; }
.tm-btn:hover:not(:disabled), .tm-tier-btn:hover:not(:disabled) {
  background: rgba(255, 255, 255, 0.14);
}
.tm-btn.on, .tm-tier-btn.on {
  border-color: #36a3ff;
  background: rgba(54, 163, 255, 0.2);
  color: #c8e7ff;
  font-weight: 600;
}
.tm-btn.primary {
  background: #e0761c;
  border-color: #e0761c;
  color: #fff;
  font-weight: 600;
}
.tm-btn.primary:hover:not(:disabled) { background: #f08328; }
.tm-btn.danger {
  background: rgba(163, 48, 42, 0.85);
  border-color: #c84840;
}
.tm-btn:disabled { opacity: 0.45; cursor: default; }

.tm-card {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 11px;
  border-radius: 7px;
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid rgba(255, 255, 255, 0.14);
}
.tm-card.mode-border-taxi { border-left: 3px solid #ffd45a; }
.tm-card.mode-border-bus { border-left: 3px solid #59bcff; }
.tm-card.mode-border-logistics { border-left: 3px solid #ff9d5c; }

.tm-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}
.tm-head-badges {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
}
.tm-badge {
  padding: 2px 7px;
  border-radius: 4px;
  font-size: 10px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  border: 1px solid transparent;
  background: #445;
}
.tm-badge.mode-taxi { background: rgba(255, 198, 30, 0.18); border-color: rgba(255, 198, 30, 0.42); color: #ffd45a; }
.tm-badge.mode-bus { background: rgba(54, 163, 255, 0.18); border-color: rgba(54, 163, 255, 0.42); color: #8ad0ff; }
.tm-badge.mode-logistics { background: rgba(242, 122, 46, 0.18); border-color: rgba(242, 122, 46, 0.42); color: #ffac75; }

.tm-type-pill {
  padding: 2px 7px;
  border-radius: 4px;
  font-size: 10px;
  font-weight: 600;
  letter-spacing: 0.02em;
  white-space: nowrap;
}
.tm-type-pill.type-loading_bay {
  background: rgba(54, 185, 255, 0.16);
  color: #7ce2ff;
  border: 1px solid rgba(54, 185, 255, 0.34);
}
.tm-type-pill.type-kerbside {
  background: rgba(255, 255, 255, 0.09);
  color: #c2cedb;
  border: 1px solid rgba(255, 255, 255, 0.16);
}

.tm-stop-count { font-size: 12px; color: #c8d2dc; font-weight: 600; white-space: nowrap; }
.tm-stop-count.is-complete { color: #6ae696; }
.tm-title { font-weight: 600; font-size: 13px; color: #fff; line-height: 1.3; }
.tm-current {
  padding: 8px 9px;
  border-radius: 5px;
  background: rgba(0, 0, 0, 0.34);
  border: 1px solid rgba(255, 255, 255, 0.06);
  display: flex;
  flex-direction: column;
  gap: 5px;
}
.tm-stop-header {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 8px;
}
.tm-stop-name { font-weight: 600; font-size: 13.5px; color: #fff; min-width: 0; }
.tm-kind-tag {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: #8c99a6;
  flex-shrink: 0;
}
.tm-stop-addr { font-size: 11px; color: #93a0ad; }
.tm-metrics {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  padding-top: 4px;
  border-top: 1px solid rgba(255, 255, 255, 0.08);
  font-size: 12px;
  color: #d6dfe8;
}
.tm-metric { display: inline-flex; align-items: baseline; gap: 5px; }
.tm-metric-k { font-size: 11px; color: #8c99a6; }

.tm-dwell { margin-top: 2px; }
.tm-dwell-row {
  display: flex;
  justify-content: space-between;
  font-size: 11px;
  color: #6ae696;
  margin-bottom: 4px;
  font-weight: 600;
}
.tm-dwell.fallback .tm-dwell-row { color: #c8e972; }
.tm-bar { height: 5px; border-radius: 3px; background: rgba(255, 255, 255, 0.14); overflow: hidden; }
.tm-bar-fill { display: block; height: 100%; transition: width 0.14s linear; }
.tm-bar-fill.dwell { background: #3ddc84; }
.tm-bar-fill.fallback { background: #a9d94c; }
.tm-bay-hint { font-size: 11px; color: #8ad0ff; margin-top: 2px; }

.tm-actions { display: flex; gap: 8px; }
.tm-actions .tm-btn { flex: 1; }

.tm-stops {
  display: flex;
  flex-direction: column;
  gap: 3px;
  max-height: 180px;
  overflow-y: auto;
  border-top: 1px solid rgba(255, 255, 255, 0.1);
  padding-top: 6px;
}
.compact .tm-stops { max-height: 150px; }
.tm-stop-row {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 4px 6px;
  border-radius: 4px;
  font-size: 12px;
  cursor: pointer;
}
.tm-stop-row:hover { background: rgba(255, 255, 255, 0.08); }
.tm-stop-row.done { opacity: 0.52; }
.tm-stop-row.current { background: rgba(54, 163, 255, 0.18); font-weight: 600; }
.tm-stop-num {
  width: 18px;
  height: 18px;
  border-radius: 50%;
  background: rgba(255, 255, 255, 0.15);
  text-align: center;
  line-height: 18px;
  font-size: 11px;
  flex-shrink: 0;
}
.tm-stop-row.done .tm-stop-num { background: rgba(61, 220, 132, 0.25); color: #6ae696; }
.tm-stop-row.current .tm-stop-num { background: #36a3ff; color: #fff; }
.tm-stop-label { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.tm-stop-kind { font-size: 10px; color: #93a0ad; text-transform: uppercase; letter-spacing: 0.03em; }

.tm-summary-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 6px;
  font-size: 12px;
}
.tm-summary-grid > div {
  display: flex;
  justify-content: space-between;
  padding: 5px 7px;
  border-radius: 4px;
  background: rgba(0, 0, 0, 0.28);
}
.tm-summary-grid > div.is-score b { color: #6ae696; }
.tm-summary-grid span { color: #93a0ad; }
.tm-note { font-size: 12px; color: #b8c2cc; }
.tm-note.is-warn { color: #ffb27a; }
.tm-note.is-error { color: #ff8a80; }
</style>
