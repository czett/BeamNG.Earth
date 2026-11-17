<template>
  <div class="tm-root" :class="{ compact }">
    <div v-if="!ready" class="tm-note is-warn">
      Load into the BeamNG.Earth world to start a transport job.
    </div>

    <!-- Active Job -->
    <template v-if="active">
      <div class="tm-card">
        <div class="tm-head">
          <span class="tm-badge" :class="'mode-' + active.mode">{{ modeLabel(active.mode) }}</span>
          <span class="tm-stop-count">Stop {{ active.stopIndex }}/{{ active.stopCount }}</span>
        </div>
        <div v-if="active.title" class="tm-title">{{ active.title }}</div>
        <div class="tm-current">
          <div class="tm-stop-name">{{ currentStop ? currentStop.name : "Next stop" }}</div>
          <div v-if="currentStop && currentStop.address" class="tm-stop-addr">{{ currentStop.address }}</div>
          <div class="tm-metrics">
            <span>To stop: <b>{{ formatDist(active.distM, metric) }}</b></span>
            <span v-if="active.etaS != null">ETA: <b>{{ formatDur(active.etaS) }}</b></span>
            <span>Score: <b>{{ active.score }}/100</b></span>
          </div>
          <div v-if="active.dwellFrac > 0" class="tm-dwell">
            <div class="tm-dwell-label">Hold inside zone ({{ Math.round(active.dwellFrac * 100) }}%)</div>
            <div class="tm-bar"><span class="tm-bar-fill dwell" :style="{ width: Math.round(active.dwellFrac * 100) + '%' }"></span></div>
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
            <span class="tm-stop-num">{{ idx + 1 }}</span>
            <span class="tm-stop-label">{{ s.name }}</span>
            <span class="tm-stop-kind">{{ s.kind }}</span>
          </div>
        </div>
      </div>
    </template>

    <!-- Pending request -->
    <template v-else-if="pending || busy">
      <div class="tm-card">
        <div class="tm-title">Generating {{ modeLabel((pending && pending.mode) || selectedMode) }} job...</div>
        <div class="tm-note">Snapping stops onto nearby drivable roads.</div>
        <div class="tm-actions">
          <button class="tm-btn danger" @click="cancelJob">Cancel</button>
        </div>
      </div>
    </template>

    <!-- Completion Summary -->
    <template v-else-if="summary">
      <div class="tm-card">
        <div class="tm-head">
          <span class="tm-badge" :class="'mode-' + summary.mode">{{ modeLabel(summary.mode) }}</span>
          <span class="tm-stop-count">Job Complete</span>
        </div>
        <div v-if="summary.title" class="tm-title">{{ summary.title }}</div>
        <div class="tm-summary-grid">
          <div><span>Stops</span><b>{{ summary.stopsCompleted }}/{{ summary.stopCount }}</b></div>
          <div><span>Distance</span><b>{{ formatDist(summary.drivenM, metric) }}</b></div>
          <div><span>Time</span><b>{{ formatDur(summary.elapsedS) }}</b></div>
          <div><span>Smoothness</span><b>{{ summary.smoothnessPct }}%</b></div>
          <div><span>Collisions</span><b>{{ summary.collisions }}</b></div>
          <div><span>Score</span><b>{{ summary.score }}/100</b></div>
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
  modeLabel, formatDist, formatDur, toArray, start, stop,
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
.tm-section-label {
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: #9aa4ae;
  margin-top: 2px;
}
.tm-mode-desc {
  font-size: 12px;
  color: #b8c2cc;
  line-height: 1.35;
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
  border-radius: 4px;
  border: 1px solid rgba(255, 255, 255, 0.24);
  background: rgba(255, 255, 255, 0.06);
  color: #eef1f4;
  font: inherit;
  font-size: 13px;
  cursor: pointer;
  text-align: center;
}
.tm-tier-btn { text-align: left; }
.tm-btn:hover:not(:disabled), .tm-tier-btn:hover:not(:disabled) {
  background: rgba(255, 255, 255, 0.14);
}
.tm-btn.on, .tm-tier-btn.on {
  border-color: #36a3ff;
  background: rgba(54, 163, 255, 0.2);
  color: #bfe2ff;
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
  padding: 10px;
  border-radius: 6px;
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid rgba(255, 255, 255, 0.14);
}
.tm-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}
.tm-badge {
  padding: 2px 7px;
  border-radius: 3px;
  font-size: 11px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  background: #445;
}
.tm-badge.mode-taxi { background: rgba(255, 198, 30, 0.25); color: #ffd45a; }
.tm-badge.mode-bus { background: rgba(54, 163, 255, 0.25); color: #8ad0ff; }
.tm-badge.mode-logistics { background: rgba(242, 122, 46, 0.25); color: #ffac75; }
.tm-stop-count { font-size: 12px; color: #c8d2dc; font-weight: 600; }
.tm-title { font-weight: 600; font-size: 13px; color: #fff; }
.tm-current {
  padding: 7px 8px;
  border-radius: 4px;
  background: rgba(0, 0, 0, 0.3);
  display: flex;
  flex-direction: column;
  gap: 4px;
}
.tm-stop-name { font-weight: 600; color: #fff; }
.tm-stop-addr { font-size: 11px; color: #9aa4ae; }
.tm-metrics {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  font-size: 12px;
  color: #cdd6df;
}
.tm-dwell { margin-top: 3px; }
.tm-dwell-label { font-size: 11px; color: #6ae696; margin-bottom: 3px; }
.tm-bar { height: 5px; border-radius: 3px; background: rgba(255, 255, 255, 0.14); overflow: hidden; }
.tm-bar-fill.dwell { display: block; height: 100%; background: #3ddc84; transition: width 0.15s linear; }
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
  padding: 4px 5px;
  border-radius: 3px;
  font-size: 12px;
  cursor: pointer;
}
.tm-stop-row:hover { background: rgba(255, 255, 255, 0.08); }
.tm-stop-row.done { opacity: 0.5; }
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
.tm-stop-row.current .tm-stop-num { background: #36a3ff; color: #fff; }
.tm-stop-label { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.tm-stop-kind { font-size: 10px; color: #9aa4ae; text-transform: uppercase; }

.tm-summary-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 6px;
  font-size: 12px;
}
.tm-summary-grid > div {
  display: flex;
  justify-content: space-between;
  padding: 4px 6px;
  border-radius: 4px;
  background: rgba(0, 0, 0, 0.25);
}
.tm-summary-grid span { color: #9aa4ae; }
.tm-note { font-size: 12px; color: #b8c2cc; }
.tm-note.is-warn { color: #ffb27a; }
.tm-note.is-error { color: #ff8a80; }
</style>
