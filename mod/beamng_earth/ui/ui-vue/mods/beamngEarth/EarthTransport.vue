<template>
  <div class="tm-root" :class="{ compact }">
    <!-- Career Overview Card -->
    <BngCard v-if="career" class="tm-card">
      <div class="tm-body">
        <div class="tm-career-head">
          <div class="tm-pills">
            <BngPill marked class="tm-pill-brand">{{ career.driverRank || 'Rookie Driver' }}</BngPill>
            <BngPill v-if="career.streak >= 2" marked class="tm-pill-ok tm-num">{{ career.streak }}x Streak</BngPill>
            <BngPill v-if="fuelPct != null" :marked="lowFuel" :class="lowFuel ? 'tm-pill-warn' : 'tm-pill-neutral'" class="tm-num">
              Fuel {{ fuelPct }}%
            </BngPill>
          </div>
          <div class="tm-career-reset">
            <template v-if="resetConfirm">
              <BngButton :accent="ACCENTS.destructive" @click="confirmResetCareer">Confirm</BngButton>
              <BngButton :accent="ACCENTS.outlined" @click="resetConfirm = false">Cancel</BngButton>
            </template>
            <BngButton
              v-else-if="career.completedJobs > 0 || career.totalEarnings !== 0"
              :accent="ACCENTS.text"
              title="Reset transport career stats"
              @click="resetConfirm = true"
            >Reset</BngButton>
          </div>
        </div>
        <div class="tm-prop-grid" :class="{ 'cols-3': compact }">
          <BngPropVal
            :icon-type="icons.beamCurrency"
            :icon-color="(career.totalEarnings || 0) < 0 ? 'var(--bng-add-red-400)' : 'var(--bng-orange-b400)'"
            key-label="Earnings"
            :value-label="formatMoney(career.totalEarnings || 0)"
            class="tm-prop"
          />
          <BngPropVal
            :icon-type="icons.flag"
            icon-color="var(--bng-cool-gray-200)"
            key-label="Jobs"
            :value-label="String(career.completedJobs || 0)"
            class="tm-prop"
          />
          <BngPropVal
            :icon-type="icons.star"
            icon-color="var(--bng-ter-yellow-300)"
            key-label="Avg Score"
            :value-label="career.completedJobs > 0 ? (career.avgScore + '/100') : '--'"
            class="tm-prop"
          />
          <BngPropVal
            v-if="!compact"
            :icon-type="icons.odometer"
            icon-color="var(--bng-cool-gray-200)"
            key-label="Distance"
            :value-label="formatCareerDist(career.totalDistanceKm || 0, metric)"
            class="tm-prop"
          />
        </div>
      </div>
    </BngCard>

    <!-- Live Refueling Progress Card -->
    <BngCard v-if="refueling && (refueling.active || refueling.done || refueling.holdS > 0)" class="tm-card">
      <div class="tm-body">
        <div class="tm-inline-head">
          <BngIcon :type="icons.fuelPumpFilling" :color="refueling.overdraftHit ? 'var(--bng-ter-yellow-400)' : 'var(--bng-add-blue-300)'" />
          <span class="tm-inline-title">{{ refuelHeading }}</span>
          <span v-if="refueling.active || refueling.done" class="tm-num tm-refuel-cost">
            +{{ Number(refueling.litersAdded || 0).toFixed(1) }} L · -{{ formatMoney(refueling.costTotal || 0) }}
          </span>
        </div>
        <BngProgressBar
          class="tm-progress"
          :value="refuelProgressValue"
          :min="0"
          :max="100"
          :show-value-label="false"
          :value-color="refueling.overdraftHit ? 'var(--bng-ter-yellow-400)' : (refueling.done && !refueling.active ? 'var(--bng-add-green-400)' : 'var(--bng-add-blue-400)')"
        />
      </div>
    </BngCard>

    <!-- Low Fuel Helper Card -->
    <BngCard v-if="lowFuel && !(refueling && refueling.active)" class="tm-card">
      <div class="tm-body tm-lowfuel-row">
        <div class="tm-lowfuel-copy">
          <div class="tm-inline-head">
            <BngIcon :type="icons.fuelPump" color="var(--bng-ter-yellow-400)" />
            <b class="tm-warn-text">Low Fuel ({{ fuelPct }}%)</b>
          </div>
          <span v-if="nearestFuelStation" class="tm-sub tm-num">
            {{ nearestFuelStation.name }} · {{ formatDist(nearestFuelStation.distM, metric) }} {{ formatHeading(nearestFuelStation.bearingDeg) }} · {{ formatMoney(nearestFuelStation.pricePerLiter) }}/L
          </span>
          <span v-else class="tm-sub">Search nearby fuel stations</span>
        </div>
        <BngButton :accent="ACCENTS.main" :icon-left="icons.fuelPump" @click="findNearestFuel">Find Fuel</BngButton>
      </div>
    </BngCard>

    <div v-if="!ready" class="tm-note is-warn">
      Load into the BeamNG.Earth world to start a transport job.
    </div>

    <!-- Active Job Card -->
    <BngCard v-if="active" class="tm-card">
      <BngCardHeading type="line">
        {{ modeLabel(active.mode) }}
        <span class="tm-heading-sub tm-num">
          {{ active.mode === 'taxi' ? (active.passengerOnBoard ? 'Drop-off' : 'Pickup') + ' · ' + tierLabel('taxi', active.tier) : ('Stop ' + active.stopIndex + '/' + active.stopCount) }}
        </span>
      </BngCardHeading>
      <div class="tm-body">
        <div v-if="active.title" class="tm-job-title">{{ active.title }}</div>

        <div class="tm-stop-block">
          <div class="tm-stop-head">
            <div class="tm-stop-name">{{ currentStop ? currentStop.name : "Next stop" }}</div>
            <div class="tm-pills">
              <BngPill v-if="currentStop" marked class="tm-pill-neutral">{{ stopTypeLabel(currentStop.stopType) }}</BngPill>
              <BngPill v-if="currentStop && currentStop.sectorLabel" class="tm-pill-neutral">{{ currentStop.sectorLabel }}</BngPill>
              <BngPill v-if="currentStop && currentStop.kind" class="tm-pill-neutral">{{ stopKindLabel(currentStop.kind) }}</BngPill>
            </div>
          </div>
          <div v-if="stopSubtitle" class="tm-sub">{{ stopSubtitle }}</div>

          <div v-if="active.mode === 'taxi'" class="tm-subline">
            <BngPill :marked="!!active.passengerOnBoard" :class="active.passengerOnBoard ? 'tm-pill-ok' : 'tm-pill-neutral'">
              {{ active.passengerOnBoard ? (active.paxCount || 1) + ' pax on board' : 'En route to pickup (' + (active.paxCount || 1) + ' pax)' }}
            </BngPill>
            <BngPill v-if="active.rideArchetype && active.rideArchetype !== 'standard'" marked class="tm-pill-brand">
              {{ active.rideArchetype === 'express' ? 'Express +40%' : 'VIP +35% tip' }}
            </BngPill>
            <span v-if="active.passengerOnBoard && active.fare != null" class="tm-num tm-accent-val">Meter {{ formatMoney(active.fare) }}</span>
          </div>
          <div v-else-if="active.mode === 'bus'" class="tm-subline">
            <span class="tm-num"><b>{{ active.paxCount ?? 0 }}/{{ active.paxCapacity || 40 }}</b> pax</span>
            <BngPill marked :class="!active.scheduleText || active.scheduleText === 'On Time' ? 'tm-pill-ok' : 'tm-pill-warn'">
              {{ active.scheduleText || 'On Time' }}
            </BngPill>
          </div>
          <div v-else-if="active.mode === 'logistics'" class="tm-subline">
            <span class="tm-sub-strong">{{ active.legLabel || (active.legKind === 'deadhead' ? 'Deadhead · Empty transit (0 kg)' : (active.cargoKg ? (active.cargoLabel || 'Cargo') + ' · ' + formatCargo(active.cargoKg) : 'Deadhead · Empty transit (0 kg)')) }}</span>
            <BngPill
              marked
              :class="active.trailerMissing ? 'tm-pill-warn' : ((active.trailerState === 'attached' || active.trailerState === 'staged') ? 'tm-pill-ok' : 'tm-pill-neutral')"
            >
              {{ logisticsBadge(active) }}
            </BngPill>
          </div>
          <div v-else-if="active.mode === 'parcel'" class="tm-subline">
            <span class="tm-num">
              <b>{{ active.parcelsRemaining ?? 0 }}/{{ active.parcelsTotal ?? 0 }}</b> parcels left · {{ formatCargo(active.cargoCurrentKg || 0) }}
              <span v-if="active.parcelsReturned > 0"> (+{{ active.parcelsReturned }} ret)</span>
            </span>
            <BngPill marked :class="active.parcelAction === 'pickup_return' ? 'tm-pill-warn' : 'tm-pill-ok'">
              {{ active.parcelAction === 'pickup_return' ? ('Return +' + (active.parcelCount || 1)) : ('Deliver ' + (active.parcelCount || 1) + 'x') }}
            </BngPill>
          </div>

          <div v-if="active.mode === 'bus' && active.nextStopName" class="tm-sub">
            Next Stop after this: {{ active.nextStopName }}
          </div>

          <div class="tm-prop-grid cols-3">
            <BngPropVal
              :icon-type="icons.location1"
              icon-color="var(--bng-orange-b400)"
              key-label="To stop"
              :value-label="formatDist(active.distM, metric)"
              class="tm-prop"
            />
            <BngPropVal
              v-if="active.etaS != null"
              :icon-type="icons.timer"
              icon-color="var(--bng-cool-gray-200)"
              key-label="ETA"
              :value-label="formatDur(active.etaS)"
              class="tm-prop"
            />
            <BngPropVal
              :icon-type="icons.star"
              icon-color="var(--bng-ter-yellow-300)"
              key-label="Score"
              :value-label="active.score + '/100'"
              class="tm-prop"
            />
          </div>

          <!-- Cargo Sensitivity & Integrity -->
          <div v-if="active.cargoSensitivity === 'fragile' || active.cargoSensitivity === 'hazmat'" class="tm-inset">
            <div class="tm-inline-head">
              <BngIcon
                :type="active.cargoSensitivity === 'hazmat' ? icons.hazard : icons.fragile"
                :color="active.cargoSensitivity === 'hazmat' ? 'var(--bng-add-red-400)' : 'var(--bng-ter-yellow-400)'"
              />
              <BngPill marked :class="active.cargoSensitivity === 'hazmat' ? 'tm-pill-danger' : 'tm-pill-warn'">
                {{ sensitivityBadgeLabel(active.cargoSensitivity) }}
              </BngPill>
              <span v-if="active.sensitivityLabel" class="tm-sub">{{ active.sensitivityLabel }}</span>
              <b class="tm-num tm-integrity-pct" :class="'tier-' + integrityTier(active.cargoIntegrity)">
                {{ Math.round(active.cargoIntegrity ?? 100) }}%
              </b>
            </div>
            <BngProgressBar
              class="tm-progress"
              :value="Math.max(0, Math.min(100, Math.round(active.cargoIntegrity ?? 100)))"
              :min="0"
              :max="100"
              :show-value-label="false"
              :value-color="integrityBarColor(active.cargoIntegrity)"
            />
          </div>

          <!-- Trailer / Bay Dwell Status -->
          <div v-if="active.trailerMissing" class="tm-hint is-warn">
            <BngIcon :type="icons.warning" color="var(--bng-ter-yellow-400)" />
            <span>{{ active.bayHint || 'Trailer missing · Go back & hitch your trailer' }}</span>
          </div>
          <div v-else-if="active.dwellFrac > 0" class="tm-inset">
            <BngProgressBar
              class="tm-progress"
              :header-left="dwellLabel"
              :header-right="dwellTimerText"
              :value="Math.round(active.dwellFrac * 100)"
              :min="0"
              :max="100"
              :show-value-label="false"
              :value-color="active.dwellMode === 'fallback' ? 'var(--bng-ter-yellow-400)' : 'var(--bng-add-green-400)'"
            />
          </div>
          <div v-else-if="active.distM != null && active.distM <= (active.trailerState === 'staged' ? 50 : 35)" class="tm-hint">
            <BngIcon :type="icons.info" color="var(--bng-add-blue-300)" />
            <span>{{ active.trailerState === 'staged' ? 'Back up to the staged trailer in the bay to hitch' : (currentStop && currentStop.stopType === 'loading_bay' ? 'Pull into the loading bay and stop' : 'Pull up to the kerbside bay and stop') }}</span>
          </div>
        </div>

        <div v-if="stops.length" class="tm-stops">
          <div
            v-for="(s, idx) in stops"
            :key="idx"
            class="tm-stop-row"
            :class="{ done: idx + 1 < active.stopIndex, current: idx + 1 === active.stopIndex }"
            @click="$emit('focus-stop', s)"
          >
            <span class="tm-stop-num tm-num">
              <BngIcon v-if="idx + 1 < active.stopIndex" :type="icons.checkmark" color="var(--bng-add-green-400)" />
              <template v-else>{{ idx + 1 }}</template>
            </span>
            <span class="tm-stop-label">
              {{ s.name }}<span v-if="s.recipient" class="tm-stop-loc"> · {{ s.recipient }}</span><span v-else-if="s.locality" class="tm-stop-loc"> · {{ s.locality }}</span>
            </span>
            <span class="tm-stop-kind">
              {{ active.mode === 'parcel' ? (s.parcelAction === 'pickup_return' ? ('Ret +' + (s.parcelCount || 1)) : ((s.parcelCount || 1) + 'x')) : (s.stopType === 'loading_bay' ? 'Bay' : stopKindLabel(s.kind)) }}
            </span>
          </div>
        </div>
      </div>
      <template #buttons>
        <BngButton :accent="ACCENTS.outlined" @click="skipStop">Skip Stop</BngButton>
        <BngButton :accent="ACCENTS.destructive" :icon-left="icons.abandon" @click="cancelJob">Cancel Job</BngButton>
      </template>
    </BngCard>

    <!-- Pending Route Generation -->
    <BngCard v-else-if="pending || busy" class="tm-card">
      <BngCardHeading type="line">{{ modeLabel((pending && pending.mode) || selectedMode) }}</BngCardHeading>
      <div class="tm-body">
        <div class="tm-job-title">Generating {{ modeLabel((pending && pending.mode) || selectedMode) }} route...</div>
        <div class="tm-sub">Finding clear loading bays and kerbside stops nearby.</div>
      </div>
      <template #buttons>
        <BngButton :accent="ACCENTS.destructive" @click="cancelJob">Cancel</BngButton>
      </template>
    </BngCard>

    <!-- Job Completion Summary Card -->
    <BngCard v-else-if="summary" class="tm-card">
      <BngCardHeading type="line">
        {{ modeLabel(summary.mode) }}
        <span class="tm-heading-sub is-ok">Complete</span>
      </BngCardHeading>
      <div class="tm-body">
        <div v-if="summary.title" class="tm-job-title">{{ summary.title }}</div>
        <div class="tm-prop-grid cols-3">
          <BngPropVal
            v-if="summary.mode === 'taxi'"
            key-label="Trip"
            :value-label="summary.stopsCompleted >= 2 ? 'Pickup -> Drop-off' : 'Skipped'"
            class="tm-prop"
          />
          <BngPropVal
            v-else
            key-label="Stops"
            :value-label="summary.stopsCompleted + '/' + summary.stopCount"
            class="tm-prop"
          />
          <BngPropVal key-label="Distance" :value-label="formatDist(summary.drivenM, metric)" class="tm-prop" />
          <BngPropVal key-label="Time" :value-label="formatDur(summary.elapsedS)" class="tm-prop" />
          <BngPropVal key-label="Smoothness" :value-label="summary.smoothnessPct + '%'" class="tm-prop" />
          <BngPropVal key-label="Collisions" :value-label="String(summary.collisions)" class="tm-prop" />
          <BngPropVal
            v-if="summary.mode === 'logistics' && summary.cargoKg"
            key-label="Cargo"
            :value-label="formatCargo(summary.cargoKg)"
            class="tm-prop"
          />
          <BngPropVal
            v-else-if="summary.mode === 'parcel'"
            key-label="Parcels"
            :value-label="(summary.parcelsDelivered ?? 0) + '/' + (summary.parcelsTotal ?? 0) + (summary.parcelsReturned > 0 ? (' (+' + summary.parcelsReturned + ' ret)') : '')"
            class="tm-prop"
          />
          <BngPropVal
            v-if="summary.cargoSensitivity === 'fragile' || summary.cargoSensitivity === 'hazmat'"
            key-label="Integrity"
            :value-label="Math.round(summary.cargoIntegrity ?? 100) + '%'"
            class="tm-prop"
          />
          <BngPropVal
            :icon-type="icons.star"
            icon-color="var(--bng-orange-b400)"
            key-label="Score"
            :value-label="summary.score + '/100'"
            class="tm-prop"
          />
        </div>

        <!-- Itemized Payout Ledger -->
        <div v-if="summary.payout" class="tm-inset tm-payout">
          <div class="tm-section-label">Payout Breakdown</div>
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
          <div v-if="summary.payout.hazardBonus > 0" class="tm-payout-row is-bonus">
            <span>{{ summary.cargoSensitivity === 'hazmat' ? 'Gefahrgut Bonus (+50%)' : 'Fragile Cargo Bonus (+35%)' }}</span>
            <b class="tm-num">{{ formatMoney(summary.payout.hazardBonus, { signed: true }) }}</b>
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
      </div>
      <template #buttons>
        <BngButton v-if="summary.mode === 'taxi'" :accent="ACCENTS.main" @click="nextPassenger">Next Passenger</BngButton>
        <BngButton :accent="summary.mode === 'taxi' ? ACCENTS.outlined : ACCENTS.main" @click="dismissSummary">New Route</BngButton>
      </template>
    </BngCard>

    <!-- Idle Job Dispatch Picker -->
    <BngCard v-if="!active && !pending && !busy && !summary" class="tm-card">
      <BngCardHeading type="line">Dispatch</BngCardHeading>
      <div class="tm-body">
        <div v-if="vehicleMatch" class="tm-veh-row">
          <BngIcon
            :type="vehicleMatch.hasTrailer ? icons.trailer : icons.car"
            :color="vehicleMatch.hasTrailer ? 'var(--bng-add-green-400)' : 'var(--bng-orange-b400)'"
          />
          <div class="tm-veh-copy">
            <span class="tm-veh-label">Vehicle: <b>{{ vehicleMatch.vehicleLabel }}</b></span>
            <span class="tm-sub">{{ vehicleMatch.readiness }}</span>
          </div>
        </div>

        <div class="tm-section-label">Mode</div>
        <div class="tm-mode-grid">
          <BngButton
            v-for="m in TRANSPORT_MODES"
            :key="m.id"
            class="tm-mode-btn"
            :accent="selectedMode === m.id ? ACCENTS.main : ACCENTS.outlined"
            :icon-left="modeIcon(m.id)"
            @click="setMode(m.id)"
          >
            {{ m.label }}
            <span v-if="isRecommendedMode(m.id)" class="tm-rec-mark" title="Recommended for current vehicle">★</span>
          </BngButton>
        </div>
        <div class="tm-sub">{{ activeModeDesc }}</div>

        <div class="tm-section-label">Scale / Distance</div>
        <BngSelect
          class="tm-tier-select"
          :value="selectedTier"
          :options="currentTiers"
          :config="tierSelectConfig"
          @valueChanged="setTier"
        />
      </div>
      <template #buttons>
        <BngButton :accent="ACCENTS.main" :icon-left="icons.routeSimple" :disabled="!ready" @click="startJob">Start Job</BngButton>
      </template>
    </BngCard>

    <div v-if="errText" class="tm-note is-error">{{ errText }}</div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onUnmounted } from "vue"
import {
  BngCard, BngCardHeading, BngButton, BngSelect, BngPropVal, BngPill, BngProgressBar, BngIcon, ACCENTS, icons,
} from "@/common/components/base"
import {
  TRANSPORT_MODES, selectedMode, selectedTier, currentTiers,
  transportState, busy, actionError,
  setMode, setTier, startJob, skipStop, cancelJob, dismissSummary, nextPassenger, resetCareerStats, findNearestFuel,
  modeLabel, tierLabel, stopTypeLabel, stopKindLabel, formatDist, formatDur, formatMoney, formatHeading, sensitivityBadgeLabel, integrityTier, toArray, start, stop,
} from "./earthTransportStore.js"

const props = defineProps({
  compact: { type: Boolean, default: false },
  externalPoll: { type: Boolean, default: false },
})
defineEmits(["focus-stop"])

const resetConfirm = ref(false)
const tierSelectConfig = { label: t => t.label, value: t => t.id }

onMounted(() => { if (!props.externalPoll) start() })
onUnmounted(() => { if (!props.externalPoll) stop() })

const st = computed(() => transportState.value || {})
const ready = computed(() => st.value.ready === true)
const active = computed(() => st.value.active || null)
const pending = computed(() => st.value.pending || null)
const summary = computed(() => st.value.summary || null)
const career = computed(() => st.value.career || null)
const vehicleMatch = computed(() => st.value.vehicleMatch || null)
const fuelPct = computed(() => st.value.fuelPct != null ? Number(st.value.fuelPct) : null)
const lowFuel = computed(() => st.value.lowFuel === true)
const nearestFuelStation = computed(() => st.value.nearestFuelStation || null)
const refueling = computed(() => st.value.refueling || null)
const metric = computed(() => st.value.metric === true)
const stops = computed(() => active.value ? toArray(active.value.stops) : [])

const recommendedSet = computed(() => {
  const list = vehicleMatch.value ? toArray(vehicleMatch.value.recommendedModes) : []
  return new Set(list)
})
function isRecommendedMode(id) {
  return recommendedSet.value.has(id)
}
function modeIcon(id) {
  if (id === "taxi") return icons.taxi
  if (id === "bus") return icons.bus
  if (id === "logistics") return icons.deliveryTruck
  if (id === "parcel") return icons.cardboardBox
  return icons.routeSimple
}
function integrityBarColor(val) {
  const tier = integrityTier(val)
  if (tier === "high") return "var(--bng-add-green-400)"
  if (tier === "mid") return "var(--bng-ter-yellow-400)"
  return "var(--bng-add-red-400)"
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
const refuelHeading = computed(() => {
  const rf = refueling.value
  if (!rf) return ""
  if (rf.active) return `Refueling at ${rf.stationName}`
  if (rf.overdraftHit) return `Overdraft Limit · ${rf.stationName}`
  if (rf.done) return `Refueled at ${rf.stationName}`
  return `Pump Ready · Hold stopped (${Number(rf.holdS || 0).toFixed(1)}/${Number(rf.holdTargetS || 1.2).toFixed(1)}s)`
})
const refuelProgressValue = computed(() => {
  const rf = refueling.value
  if (!rf) return 0
  if (rf.active || rf.done) return Math.max(0, Math.min(100, fuelPct.value ?? 0))
  return Math.max(0, Math.min(100, Math.round(((rf.holdS || 0) / (rf.holdTargetS || 1.2)) * 100)))
})
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

<style scoped lang="scss">
.tm-root {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  font-family: "Overpass", var(--fnt-defs);
  color: var(--bng-off-white);
}

.tm-num {
  font-variant-numeric: tabular-nums;
}

.tm-card {
  --bg-opacity: 0.72;
  width: 100%;
}

.tm-body {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  padding: 0.5rem 0.75rem 0.75rem;
}

.tm-heading-sub {
  margin-left: 0.5rem;
  font-size: 0.85rem;
  font-weight: 600;
  font-style: normal;
  color: var(--bng-cool-gray-300);

  &.is-ok {
    color: var(--bng-add-green-400);
  }
}

.tm-career-head,
.tm-stop-head,
.tm-subline,
.tm-inline-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.4rem;
  flex-wrap: wrap;
}

.tm-inline-head {
  justify-content: flex-start;
}

.tm-inline-title {
  font-weight: 700;
  font-size: 0.9rem;
  color: var(--bng-off-white);
  flex: 1 1 auto;
  min-width: 0;
}

.tm-refuel-cost {
  font-weight: 700;
  font-size: 0.85rem;
  color: var(--bng-add-blue-300);
  white-space: nowrap;
}

.tm-pills {
  display: flex;
  align-items: center;
  gap: 0.35rem;
  flex-wrap: wrap;
  min-width: 0;
}

.tm-pill-brand {
  --bng-pill-marked-background-color: var(--bng-orange-700);
  --bng-pill-text-color: var(--bng-off-white);
  font-size: 0.75rem;
  padding: 0.15em 0.6em;
}

.tm-pill-ok {
  --bng-pill-marked-background-color: var(--bng-add-green-700);
  --bng-pill-text-color: var(--bng-off-white);
  font-size: 0.75rem;
  padding: 0.15em 0.6em;
}

.tm-pill-warn {
  --bng-pill-marked-background-color: var(--bng-ter-yellow-700);
  --bng-pill-text-color: var(--bng-off-white);
  font-size: 0.75rem;
  padding: 0.15em 0.6em;
}

.tm-pill-danger {
  --bng-pill-marked-background-color: var(--bng-add-red-700);
  --bng-pill-text-color: var(--bng-off-white);
  font-size: 0.75rem;
  padding: 0.15em 0.6em;
}

.tm-pill-neutral {
  --bng-pill-marked-background-color: var(--bng-ter-blue-gray-800);
  --bng-pill-default-border-color: var(--bng-ter-blue-gray-600);
  --bng-pill-text-color: var(--bng-cool-gray-100);
  font-size: 0.75rem;
  padding: 0.15em 0.6em;
}

.tm-career-reset {
  display: flex;
  align-items: center;
  gap: 0.25rem;
  flex-shrink: 0;
}

.tm-prop-grid {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 0.35rem 0.5rem;

  &.cols-3 {
    grid-template-columns: repeat(3, minmax(0, 1fr));
  }
}

.tm-prop {
  --icon-size: 1.15em;
  font-size: 0.85rem;
}

.tm-lowfuel-row {
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
}

.tm-lowfuel-copy {
  display: flex;
  flex-direction: column;
  gap: 0.15rem;
  min-width: 0;
  flex: 1 1 auto;
}

.tm-warn-text {
  color: var(--bng-ter-yellow-300);
  font-size: 0.9rem;
}

.tm-job-title {
  font-size: 0.9rem;
  font-weight: 600;
  color: var(--bng-cool-gray-200);
}

.tm-stop-block {
  display: flex;
  flex-direction: column;
  gap: 0.45rem;
}

.tm-stop-name {
  font-size: 1.05rem;
  font-weight: 700;
  color: var(--bng-off-white);
  min-width: 0;
}

.tm-sub {
  font-size: 0.82rem;
  color: var(--bng-cool-gray-300);
  line-height: 1.35;
}

.tm-sub-strong {
  font-size: 0.85rem;
  color: var(--bng-cool-gray-100);
}

.tm-accent-val {
  font-weight: 700;
  color: var(--bng-orange-300);
}

.tm-inset {
  display: flex;
  flex-direction: column;
  gap: 0.35rem;
  padding: 0.5rem 0.65rem;
  border-radius: var(--bng-corners-1);
  background: rgba(var(--bng-ter-blue-gray-900-rgb), 0.65);
}

.tm-progress {
  font-size: 0.8rem;
  width: 100%;
}

.tm-integrity-pct {
  margin-left: auto;
  font-size: 0.85rem;

  &.tier-high { color: var(--bng-add-green-400); }
  &.tier-mid { color: var(--bng-ter-yellow-300); }
  &.tier-low { color: var(--bng-add-red-400); }
}

.tm-hint {
  display: flex;
  align-items: center;
  gap: 0.4rem;
  font-size: 0.82rem;
  color: var(--bng-add-blue-200);

  &.is-warn {
    color: var(--bng-ter-yellow-300);
    font-weight: 600;
  }
}

.tm-stops {
  display: flex;
  flex-direction: column;
  gap: 0.2rem;
  max-height: 11rem;
  overflow-y: auto;
  padding-top: 0.35rem;
  border-top: 1px solid rgba(var(--bng-cool-gray-600-rgb), 0.35);
}

.tm-stop-row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.3rem 0.45rem;
  border-radius: var(--bng-corners-1);
  font-size: 0.82rem;
  cursor: pointer;
  color: var(--bng-cool-gray-200);

  &:hover {
    background: rgba(var(--bng-cool-gray-700-rgb), 0.35);
  }

  &.done {
    color: var(--bng-cool-gray-400);
  }

  &.current {
    background: rgba(var(--bng-orange-600-rgb), 0.24);
    color: var(--bng-off-white);
    font-weight: 600;
  }
}

.tm-stop-num {
  width: 1.35rem;
  text-align: center;
  flex-shrink: 0;
  font-weight: 700;
  color: var(--bng-cool-gray-300);
}

.tm-stop-label {
  flex: 1 1 auto;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.tm-stop-loc {
  color: var(--bng-cool-gray-400);
  font-weight: 400;
}

.tm-stop-kind {
  font-size: 0.75rem;
  color: var(--bng-cool-gray-300);
  white-space: nowrap;
  flex-shrink: 0;
}

.tm-section-label {
  font-size: 0.75rem;
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--bng-cool-gray-300);
}

.tm-payout-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  font-size: 0.85rem;
  color: var(--bng-cool-gray-200);

  &.is-bonus { color: var(--bng-add-green-300); }
  &.is-penalty { color: var(--bng-add-red-300); }
}

.tm-payout-total {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding-top: 0.35rem;
  margin-top: 0.15rem;
  border-top: 1px solid rgba(var(--bng-cool-gray-600-rgb), 0.4);
  font-size: 0.95rem;
  font-weight: 700;
  color: var(--bng-orange-300);
}

.tm-veh-row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.45rem 0.6rem;
  border-radius: var(--bng-corners-1);
  background: rgba(var(--bng-ter-blue-gray-900-rgb), 0.65);
}

.tm-veh-copy {
  display: flex;
  flex-direction: column;
  gap: 0.1rem;
  min-width: 0;
}

.tm-veh-label {
  font-size: 0.85rem;
  color: var(--bng-off-white);
}

.tm-mode-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.35rem;
}

.tm-mode-btn {
  max-width: none;
  justify-content: flex-start;
}

.tm-rec-mark {
  margin-left: 0.35rem;
  color: var(--bng-ter-yellow-300);
}

.tm-tier-select {
  width: 100%;
}

.tm-note {
  font-size: 0.85rem;
  padding: 0.45rem 0.65rem;
  border-radius: var(--bng-corners-1);
  background: rgba(var(--bng-off-black-rgb), 0.65);
  color: var(--bng-cool-gray-200);

  &.is-warn {
    color: var(--bng-ter-yellow-300);
  }

  &.is-error {
    color: var(--bng-add-red-300);
  }
}

.tm-root.compact {
  gap: 0.4rem;

  .tm-body {
    padding: 0.4rem 0.6rem 0.55rem;
    gap: 0.4rem;
  }

  .tm-prop-grid {
    grid-template-columns: repeat(3, minmax(0, 1fr));
  }
}
</style>
