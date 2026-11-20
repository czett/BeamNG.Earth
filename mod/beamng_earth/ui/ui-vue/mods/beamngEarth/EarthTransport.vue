<template>
  <div class="tm-root" :class="{ compact }">
    <!-- Compact Career Strip -->
    <div v-if="career" class="tm-career">
      <div class="tm-career-top">
        <div class="tm-rank-wrap">
          <span class="tm-rank-badge">{{ career.driverRank || 'Rookie Driver' }}</span>
          <span v-if="career.streak >= 2" class="tm-streak-pill tm-num">{{ career.streak }}x streak</span>
        </div>
        <div class="tm-career-reset">
          <template v-if="resetConfirm">
            <button class="tm-mini-btn danger" @click="confirmResetCareer">Confirm</button>
            <button class="tm-mini-btn" @click="resetConfirm = false">Cancel</button>
          </template>
          <button
            v-else-if="career.completedJobs > 0 || career.totalEarnings > 0"
            class="tm-mini-btn"
            title="Reset transport career stats"
            @click="resetConfirm = true"
          >Reset</button>
        </div>
      </div>
      <div class="tm-career-stats">
        <div class="tm-cstat">
          <span class="tm-cstat-k">Earnings</span>
          <b class="tm-num is-accent">{{ formatMoney(career.totalEarnings || 0) }}</b>
        </div>
        <div class="tm-cstat">
          <span class="tm-cstat-k">Jobs</span>
          <b class="tm-num">{{ career.completedJobs || 0 }}</b>
        </div>
        <div class="tm-cstat">
          <span class="tm-cstat-k">Avg Score</span>
          <b class="tm-num">{{ career.completedJobs > 0 ? (career.avgScore + '/100') : '--' }}</b>
        </div>
        <div v-if="!compact" class="tm-cstat">
          <span class="tm-cstat-k">Distance</span>
          <b class="tm-num">{{ formatCareerDist(career.totalDistanceKm || 0, metric) }}</b>
        </div>
      </div>
    </div>

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
          <span v-if="active.mode === 'taxi'" class="tm-stop-count tm-num">{{ active.passengerOnBoard ? 'Drop-off' : 'Pickup' }} · {{ tierLabel('taxi', active.tier) }}</span>
          <span v-else class="tm-stop-count tm-num">Stop {{ active.stopIndex }}/{{ active.stopCount }}</span>
        </div>
        <div v-if="active.title" class="tm-title">{{ active.title }}</div>
        <div class="tm-current">
          <div class="tm-stop-header">
            <div class="tm-stop-name">{{ currentStop ? currentStop.name : "Next stop" }}</div>
            <div class="tm-stop-tags">
              <span v-if="currentStop && currentStop.sectorLabel" class="tm-sector-tag">{{ currentStop.sectorLabel }}</span>
              <span v-if="currentStop && currentStop.kind" class="tm-kind-tag">{{ stopKindLabel(currentStop.kind) }}</span>
            </div>
          </div>
          <div v-if="stopSubtitle" class="tm-stop-addr">{{ stopSubtitle }}</div>
          <div v-if="active.mode === 'taxi'" class="tm-subline">
            <span class="tm-pill" :class="{ on: active.passengerOnBoard }">
              {{ active.passengerOnBoard ? (active.paxCount || 1) + ' pax on board' : 'En route to pickup (' + (active.paxCount || 1) + ' pax)' }}
            </span>
            <span v-if="active.rideArchetype && active.rideArchetype !== 'standard'" class="tm-pill on">
              {{ active.rideArchetype === 'express' ? 'Express +40%' : 'VIP +35% tip' }}
            </span>
            <span v-if="active.passengerOnBoard && active.fare != null" class="tm-num tm-fare">Meter {{ formatMoney(active.fare) }}</span>
          </div>
          <div v-else-if="active.mode === 'bus'" class="tm-subline">
            <span class="tm-num"><b>{{ active.paxCount ?? 0 }}/{{ active.paxCapacity || 40 }}</b> pax</span>
            <span class="tm-pill" :class="{ on: !active.scheduleText || active.scheduleText === 'On Time' }">{{ active.scheduleText || 'On Time' }}</span>
          </div>
          <div v-else-if="active.mode === 'logistics'" class="tm-subline">
            <span>{{ active.legLabel || (active.legKind === 'deadhead' ? 'Deadhead · Empty transit (0 kg)' : (active.cargoKg ? (active.cargoLabel || 'Cargo') + ' · ' + formatCargo(active.cargoKg) : 'Deadhead · Empty transit (0 kg)')) }}</span>
            <span class="tm-pill" :class="{ on: !active.trailerMissing && (active.trailerState === 'attached' || active.trailerState === 'staged'), warn: active.trailerMissing }">
              {{ logisticsBadge(active) }}
            </span>
          </div>
          <div v-else-if="active.mode === 'parcel'" class="tm-subline">
            <span class="tm-num">
              <b>{{ active.parcelsRemaining ?? 0 }}/{{ active.parcelsTotal ?? 0 }}</b> parcels left · {{ formatCargo(active.cargoCurrentKg || 0) }}
              <span v-if="active.parcelsReturned > 0"> (+{{ active.parcelsReturned }} ret)</span>
            </span>
            <span class="tm-pill" :class="{ on: active.parcelAction !== 'pickup_return', warn: active.parcelAction === 'pickup_return' }">
              {{ active.parcelAction === 'pickup_return' ? ('Return +' + (active.parcelCount || 1)) : ('Deliver ' + (active.parcelCount || 1) + 'x') }}
            </span>
          </div>
          <div v-if="active.mode === 'bus' && active.nextStopName" class="tm-stop-addr">
            Next Stop after this: {{ active.nextStopName }}
          </div>
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
          <div v-if="active.trailerMissing" class="tm-bay-hint is-warn">
            {{ active.bayHint || 'Trailer missing · Go back & hitch your trailer' }}
          </div>
          <div v-else-if="active.dwellFrac > 0" class="tm-dwell" :class="{ fallback: active.dwellMode === 'fallback' }">
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
          <div v-else-if="active.distM != null && active.distM <= (active.trailerState === 'staged' ? 50 : 35)" class="tm-bay-hint">
            {{ active.trailerState === 'staged' ? 'Back up to the staged trailer in the bay to hitch' : (currentStop && currentStop.stopType === 'loading_bay' ? 'Pull into the loading bay and stop' : 'Pull up to the kerbside bay and stop') }}
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
            <span class="tm-stop-label">{{ s.name }}<span v-if="s.recipient" class="tm-stop-loc"> · {{ s.recipient }}</span><span v-else-if="s.locality" class="tm-stop-loc"> · {{ s.locality }}</span></span>
            <span class="tm-stop-kind">{{ active.mode === 'parcel' ? (s.parcelAction === 'pickup_return' ? ('↩ ' + (s.parcelCount || 1) + 'x') : ((s.parcelCount || 1) + 'x')) : (s.stopType === 'loading_bay' ? 'Bay' : stopKindLabel(s.kind)) }}</span>
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
          <div v-if="summary.mode === 'taxi'"><span>Trip</span><b class="tm-num">{{ summary.stopsCompleted >= 2 ? 'Pickup -> Drop-off' : 'Skipped' }}</b></div>
          <div v-else><span>Stops</span><b class="tm-num">{{ summary.stopsCompleted }}/{{ summary.stopCount }}</b></div>
          <div><span>Distance</span><b class="tm-num">{{ formatDist(summary.drivenM, metric) }}</b></div>
          <div><span>Time</span><b class="tm-num">{{ formatDur(summary.elapsedS) }}</b></div>
          <div><span>Smoothness</span><b class="tm-num">{{ summary.smoothnessPct }}%</b></div>
          <div><span>Collisions</span><b class="tm-num">{{ summary.collisions }}</b></div>
          <div v-if="summary.mode === 'logistics' && summary.cargoKg"><span>Cargo</span><b class="tm-num">{{ formatCargo(summary.cargoKg) }}</b></div>
          <div v-else-if="summary.mode === 'parcel'"><span>Parcels</span><b class="tm-num">{{ summary.parcelsDelivered ?? 0 }}/{{ summary.parcelsTotal ?? 0 }}<span v-if="summary.parcelsReturned > 0"> (+{{ summary.parcelsReturned }} ret)</span></b></div>
          <div class="is-score"><span>Score</span><b class="tm-num">{{ summary.score }}/100</b></div>
        </div>

        <!-- Itemized Payout Breakdown -->
        <div v-if="summary.payout" class="tm-payout">
          <div class="tm-payout-head">Payout Breakdown</div>
          <div class="tm-payout-row">
            <span>{{ summary.mode === 'taxi' ? 'Base Fare' : 'Route Base Pay' }}</span>
            <b class="tm-num">{{ formatMoney(summary.payout.basePay) }}</b>
          </div>
          <div v-if="summary.payout.timeBonus > 0" class="tm-payout-row is-bonus">
            <span>Schedule / Time Bonus</span>
            <b class="tm-num">{{ formatMoney(summary.payout.timeBonus, { signed: true }) }}</b>
          </div>
          <div v-if="summary.payout.smoothnessBonus > 0" class="tm-payout-row is-bonus">
            <span>Smoothness &amp; Comfort Bonus</span>
            <b class="tm-num">{{ formatMoney(summary.payout.smoothnessBonus, { signed: true }) }}</b>
          </div>
          <div v-if="summary.payout.tipOrStreakBonus > 0" class="tm-payout-row is-bonus">
            <span>{{ summary.mode === 'taxi' ? 'Tip &amp; Streak Bonus' : 'Clean Streak Bonus' }}</span>
            <b class="tm-num">{{ formatMoney(summary.payout.tipOrStreakBonus, { signed: true }) }}</b>
          </div>
          <div v-if="summary.payout.damagePenalty > 0" class="tm-payout-row is-penalty">
            <span>Damage / Skip Deduction</span>
            <b class="tm-num">-{{ formatMoney(summary.payout.damagePenalty) }}</b>
          </div>
          <div class="tm-payout-total">
            <span>Total Earned</span>
            <b class="tm-num">{{ formatMoney(summary.payout.totalEarned, { signed: summary.payout.totalEarned > 0 }) }}</b>
          </div>
        </div>

        <div class="tm-actions">
          <button v-if="summary.mode === 'taxi'" class="tm-btn primary" @click="nextPassenger">Next Passenger</button>
          <button class="tm-btn" :class="{ primary: summary.mode !== 'taxi' }" @click="dismissSummary">New Route</button>
        </div>
      </div>
    </template>

    <!-- Idle Job Picker -->
    <template v-if="!active && !pending && !busy && !summary">
      <div v-if="vehicleMatch" class="tm-veh-banner">
        <span class="tm-veh-dot" :class="{ hitched: vehicleMatch.hasTrailer }"></span>
        <div class="tm-veh-text">
          <span class="tm-veh-label">Current Vehicle: <b>{{ vehicleMatch.vehicleLabel }}</b></span>
          <span class="tm-veh-sub">{{ vehicleMatch.readiness }}</span>
        </div>
      </div>

      <div class="tm-section-label">Mode</div>
      <div class="tm-seg">
        <button
          v-for="m in TRANSPORT_MODES"
          :key="m.id"
          class="tm-btn"
          :class="{ on: selectedMode === m.id, rec: isRecommendedMode(m.id) }"
          @click="setMode(m.id)"
        >
          <span>{{ m.label }}</span>
          <span v-if="isRecommendedMode(m.id)" class="tm-rec-dot" title="Recommended for current vehicle"></span>
        </button>
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
import { ref, computed, onMounted, onUnmounted } from "vue"
import {
  TRANSPORT_MODES, selectedMode, selectedTier, currentTiers,
  transportState, busy, actionError,
  setMode, setTier, startJob, skipStop, cancelJob, dismissSummary, nextPassenger, resetCareerStats,
  modeLabel, tierLabel, stopTypeLabel, stopKindLabel, formatDist, formatDur, formatMoney, toArray, start, stop,
} from "./earthTransportStore.js"

const props = defineProps({
  compact: { type: Boolean, default: false },
  externalPoll: { type: Boolean, default: false },
})
defineEmits(["focus-stop"])

const resetConfirm = ref(false)

onMounted(() => { if (!props.externalPoll) start() })
onUnmounted(() => { if (!props.externalPoll) stop() })

const st = computed(() => transportState.value || {})
const ready = computed(() => st.value.ready === true)
const active = computed(() => st.value.active || null)
const pending = computed(() => st.value.pending || null)
const summary = computed(() => st.value.summary || null)
const career = computed(() => st.value.career || null)
const vehicleMatch = computed(() => st.value.vehicleMatch || null)
const metric = computed(() => st.value.metric === true)
const stops = computed(() => active.value ? toArray(active.value.stops) : [])
const recommendedSet = computed(() => {
  const list = vehicleMatch.value ? toArray(vehicleMatch.value.recommendedModes) : []
  return new Set(list)
})
function isRecommendedMode(id) {
  return recommendedSet.value.has(id)
}
function confirmResetCareer() {
  resetConfirm.value = false
  resetCareerStats()
}
function formatCareerDist(km, isMetric) {
  const v = Number(km) || 0
  if (isMetric) return `${v.toFixed(v < 100 ? 1 : 0)} km`
  const mi = v * 0.621371
  return `${mi.toFixed(mi < 100 ? 1 : 0)} mi`
}
const currentStop = computed(() => {
  if (!active.value || !stops.value.length) return null
  return stops.value[(active.value.stopIndex || 1) - 1] || null
})
const stopSubtitle = computed(() => {
  const s = currentStop.value
  if (!s) return ""
  const addr = String(s.address || "").trim()
  const loc = String(s.locality || "").trim()
  if (addr && loc) {
    return addr.toLowerCase().includes(loc.toLowerCase()) ? addr : `${addr} · ${loc}`
  }
  return addr || loc
})
const dwellLabel = computed(() => {
  if (!active.value) return "Hold in bay"
  if (active.value.dwellLabel) return active.value.dwellLabel
  return active.value.dwellMode === "fallback" ? "Kerbside fallback" : "Hold in bay"
})
const dwellTimerText = computed(() => {
  if (!active.value) return ""
  const target = Number(active.value.dwellTargetS || (active.value.dwellMode === "fallback" ? 5.0 : 2.5))
  const cur = active.value.dwellS != null ? Number(active.value.dwellS) : Number(active.value.dwellFrac || 0) * target
  const rem = Math.max(0, target - cur)
  return `${cur.toFixed(1)} / ${target.toFixed(1)} s (${rem.toFixed(1)} s left)`
})
function formatCargo(kg) {
  const v = Number(kg) || 0
  return v >= 1000 ? `${(v / 1000).toFixed(1)} t` : `${Math.round(v)} kg`
}
function logisticsBadge(act) {
  if (!act) return "Solo"
  if (act.trailerMissing) return "Trailer Missing"
  if (act.trailerState === "staged") return "Hook Up"
  if (act.trailerState === "attached") return "Trailer Hitched"
  if (act.legKind === "deadhead") return "Deadhead"
  if (act.legKind === "pickup_approach") return "Pickup"
  if (act.trailerState === "tight_space_solo") return "Solo (Tight)"
  return "Solo"
}
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
  color: #edf1f6;
}
.tm-num {
  font-variant-numeric: tabular-nums;
}

/* Career Strip */
.tm-career {
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 8px 10px;
  border-radius: 6px;
  background: rgba(16, 20, 26, 0.90);
  border: 1px solid rgba(255, 255, 255, 0.11);
}
.tm-career-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 6px;
}
.tm-rank-wrap {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
}
.tm-rank-badge {
  padding: 2px 7px;
  border-radius: 4px;
  font-size: 10.5px;
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  background: rgba(255, 102, 0, 0.16);
  border: 1px solid rgba(255, 102, 0, 0.44);
  color: #ff9c47;
}
.tm-streak-pill {
  padding: 1px 6px;
  border-radius: 3px;
  font-size: 10px;
  font-weight: 600;
  background: rgba(61, 220, 132, 0.14);
  border: 1px solid rgba(61, 220, 132, 0.34);
  color: #6ae696;
}
.tm-career-reset {
  display: flex;
  gap: 4px;
  flex-shrink: 0;
}
.tm-mini-btn {
  padding: 2px 7px;
  border-radius: 3px;
  border: 1px solid rgba(255, 255, 255, 0.16);
  background: rgba(255, 255, 255, 0.05);
  color: #a9b5c2;
  font: inherit;
  font-size: 10.5px;
  cursor: pointer;
}
.tm-mini-btn:hover { background: rgba(255, 255, 255, 0.12); color: #fff; }
.tm-mini-btn.danger {
  background: rgba(180, 52, 46, 0.78);
  border-color: rgba(224, 92, 84, 0.65);
  color: #fff;
}
.tm-career-stats {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 6px;
}
.tm-root:not(.compact) .tm-career-stats {
  grid-template-columns: repeat(4, 1fr);
}
.tm-cstat {
  display: flex;
  flex-direction: column;
  padding: 4px 6px;
  border-radius: 4px;
  background: rgba(0, 0, 0, 0.28);
  border: 1px solid rgba(255, 255, 255, 0.05);
}
.tm-cstat-k {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: #8492a0;
}
.tm-cstat b {
  font-size: 12.5px;
  color: #eef3f8;
}
.tm-cstat b.is-accent {
  color: #f59e0b;
}

/* Vehicle Match Banner */
.tm-veh-banner {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 7px 10px;
  border-radius: 6px;
  background: rgba(16, 20, 26, 0.90);
  border: 1px solid rgba(255, 255, 255, 0.11);
  border-left: 3px solid #f59e0b;
}
.tm-veh-dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: #f59e0b;
  flex-shrink: 0;
}
.tm-veh-dot.hitched { background: #3ddc84; }
.tm-veh-text {
  display: flex;
  flex-direction: column;
  gap: 1px;
  min-width: 0;
}
.tm-veh-label {
  font-size: 12px;
  color: #dce4ec;
}
.tm-veh-sub {
  font-size: 11px;
  color: #93a1af;
}

.tm-section-label {
  font-size: 10.5px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: #8896a4;
  margin-top: 2px;
}
.tm-mode-desc {
  font-size: 12px;
  color: #b4c0cc;
  line-height: 1.4;
}
.tm-seg {
  display: flex;
  flex-wrap: wrap;
  gap: 5px;
}
.tm-seg .tm-btn {
  flex: 1 1 70px;
  padding: 6px 6px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 5px;
}
.tm-rec-dot {
  width: 5px;
  height: 5px;
  border-radius: 50%;
  background: #f59e0b;
  flex-shrink: 0;
}
.tm-tiers {
  display: flex;
  flex-direction: column;
  gap: 5px;
}
.tm-btn, .tm-tier-btn {
  padding: 6px 10px;
  border-radius: 5px;
  border: 1px solid rgba(255, 255, 255, 0.14);
  background: rgba(16, 20, 26, 0.90);
  color: #e6ecf2;
  font: inherit;
  font-size: 12.5px;
  cursor: pointer;
  text-align: center;
  transition: background 0.12s ease, border-color 0.12s ease;
}
.tm-tier-btn { text-align: left; }
.tm-btn:hover:not(:disabled), .tm-tier-btn:hover:not(:disabled) {
  background: rgba(255, 255, 255, 0.11);
  border-color: rgba(255, 255, 255, 0.24);
}
.tm-btn.on, .tm-tier-btn.on {
  border-color: #ff6600;
  background: rgba(255, 102, 0, 0.18);
  color: #ffd6b5;
  font-weight: 600;
}
.tm-btn.primary {
  background: #ff6600;
  border-color: #ff7a1f;
  color: #fff;
  font-weight: 700;
}
.tm-btn.primary:hover:not(:disabled) { background: #ff791f; }
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
  border-radius: 6px;
  background: rgba(16, 20, 26, 0.90);
  border: 1px solid rgba(255, 255, 255, 0.12);
}
.tm-card.mode-border-taxi { border-left: 3px solid #f59e0b; }
.tm-card.mode-border-bus { border-left: 3px solid #38bdf8; }
.tm-card.mode-border-logistics { border-left: 3px solid #ff6600; }
.tm-card.mode-border-parcel { border-left: 3px solid #34d399; }

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
  background: #334;
}
.tm-badge.mode-taxi { background: rgba(245, 158, 11, 0.18); border-color: rgba(245, 158, 11, 0.45); color: #fbbf24; }
.tm-badge.mode-bus { background: rgba(56, 189, 248, 0.18); border-color: rgba(56, 189, 248, 0.45); color: #7dd3fc; }
.tm-badge.mode-logistics { background: rgba(255, 102, 0, 0.18); border-color: rgba(255, 102, 0, 0.45); color: #ff9c47; }
.tm-badge.mode-parcel { background: rgba(52, 211, 153, 0.18); border-color: rgba(52, 211, 153, 0.45); color: #6ee7b7; }

.tm-type-pill {
  padding: 2px 7px;
  border-radius: 4px;
  font-size: 10px;
  font-weight: 600;
  letter-spacing: 0.02em;
  white-space: nowrap;
}
.tm-type-pill.type-loading_bay {
  background: rgba(56, 189, 248, 0.15);
  color: #7dd3fc;
  border: 1px solid rgba(56, 189, 248, 0.34);
}
.tm-type-pill.type-kerbside {
  background: rgba(255, 255, 255, 0.08);
  color: #c2cedb;
  border: 1px solid rgba(255, 255, 255, 0.14);
}

.tm-stop-count { font-size: 12px; color: #c8d2dc; font-weight: 600; white-space: nowrap; }
.tm-stop-count.is-complete { color: #6ae696; }
.tm-title { font-weight: 600; font-size: 13px; color: #fff; line-height: 1.3; }
.tm-current {
  padding: 8px 9px;
  border-radius: 5px;
  background: rgba(0, 0, 0, 0.32);
  border: 1px solid rgba(255, 255, 255, 0.07);
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
.tm-stop-tags {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  flex-shrink: 0;
}
.tm-sector-tag {
  padding: 1px 5px;
  border-radius: 3px;
  font-size: 10px;
  font-weight: 600;
  background: rgba(255, 255, 255, 0.08);
  color: #b4c5d6;
  border: 1px solid rgba(255, 255, 255, 0.12);
}
.tm-kind-tag {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: #8c99a6;
  flex-shrink: 0;
}
.tm-stop-loc { color: #8c99a6; font-weight: 400; font-size: 11px; }
.tm-stop-addr { font-size: 11px; color: #93a0ad; }
.tm-metrics {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  padding-top: 5px;
  border-top: 1px solid rgba(255, 255, 255, 0.08);
  font-size: 12px;
  color: #d6dfe8;
}
.tm-metric { display: inline-flex; align-items: baseline; gap: 5px; }
.tm-metric-k { font-size: 11px; color: #8c99a6; }
.tm-subline {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  font-size: 11.5px;
  color: #cdd6df;
}
.tm-pill {
  padding: 1px 6px;
  border-radius: 3px;
  font-size: 10px;
  font-weight: 600;
  background: rgba(255, 255, 255, 0.09);
  color: #b8c4d0;
}
.tm-pill.on {
  background: rgba(61, 220, 132, 0.18);
  color: #6ae696;
}
.tm-pill.warn {
  background: rgba(245, 158, 11, 0.22);
  color: #fbbf24;
}
.tm-fare { font-weight: 700; color: #fbbf24; }

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
.tm-bar { height: 6px; border-radius: 3px; background: rgba(255, 255, 255, 0.14); overflow: hidden; }
.tm-bar-fill { display: block; height: 100%; transition: width 0.14s linear; }
.tm-bar-fill.dwell { background: #3ddc84; }
.tm-bar-fill.fallback { background: #a9d94c; }
.tm-bay-hint { font-size: 11px; color: #7dd3fc; margin-top: 2px; }
.tm-bay-hint.is-warn { color: #fbbf24; font-weight: 600; }

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
.tm-stop-row.current { background: rgba(255, 102, 0, 0.16); font-weight: 600; }
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
.tm-stop-row.current .tm-stop-num { background: #ff6600; color: #fff; }
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
  border: 1px solid rgba(255, 255, 255, 0.05);
}
.tm-summary-grid > div.is-score b { color: #6ae696; }
.tm-summary-grid span { color: #93a0ad; }

/* Itemized Payout Breakdown */
.tm-payout {
  display: flex;
  flex-direction: column;
  gap: 4px;
  padding: 8px 9px;
  border-radius: 5px;
  background: rgba(0, 0, 0, 0.34);
  border: 1px solid rgba(255, 255, 255, 0.09);
}
.tm-payout-head {
  font-size: 10px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: #8c99a6;
  margin-bottom: 2px;
}
.tm-payout-row {
  display: flex;
  justify-content: space-between;
  font-size: 12px;
  color: #cdd6df;
}
.tm-payout-row.is-bonus { color: #8be9a8; }
.tm-payout-row.is-penalty { color: #ff9c94; }
.tm-payout-total {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  margin-top: 3px;
  padding-top: 5px;
  border-top: 1px solid rgba(255, 255, 255, 0.11);
  font-size: 13px;
  font-weight: 700;
  color: #fff;
}
.tm-payout-total b { color: #f59e0b; font-size: 14px; }

.tm-note { font-size: 12px; color: #b8c2cc; }
.tm-note.is-warn { color: #ffb27a; }
.tm-note.is-error { color: #ff8a80; }
</style>
