<template>
  <div class="nv-root">
    <BngCard class="nv-card">
      <BngCardHeading type="line">
        Turn-by-Turn Navigation
        <span class="nv-pills">
          <BngPill marked :class="st.active ? 'nv-pill-ok' : 'nv-pill-neutral'">
            {{ st.active ? "ACTIVE ROUTE" : "STANDBY" }}
          </BngPill>
        </span>
      </BngCardHeading>

      <div class="nv-body">
        <div class="nv-preview">
          <div class="nv-preview-top">
            <span class="nv-preview-label">HUD Design</span>
            <BngButton :accent="ACCENTS.outlined" @click="cycleDesign">Cycle Design</BngButton>
          </div>
          <div class="nv-designs">
            <BngButton
              v-for="d in designOptions"
              :key="d.value"
              class="nv-design-btn"
              :accent="(st.navDesign || 'gmaps_card') === d.value ? ACCENTS.main : ACCENTS.outlined"
              @click="setDesign(d.value)"
            >{{ d.label }}</BngButton>
          </div>
          <div class="nv-design-desc">{{ activeDesignDesc }}</div>
        </div>

        <div v-if="st.active" class="nv-live">
          <div class="nv-live-head">
            <span class="nv-live-dist nv-num">{{ formattedDist }}</span>
            <span class="nv-live-street">{{ st.streetName || st.destName || "Continue on route" }}</span>
          </div>
          <div class="nv-live-meta nv-num">
            <span>Remaining: {{ formattedRem }}</span>
            <span>ETA: {{ formattedEta }}</span>
            <span v-if="st.nextStreetName">Then: {{ st.nextStreetName }}</span>
          </div>
        </div>

        <div class="nv-settings">
          <BngRow class="nv-row">
            <template #label>Show Turn-by-Turn HUD</template>
            <BngSwitch :modelValue="st.enabled !== false" @update:modelValue="val => setEnabled(val)" />
          </BngRow>

          <BngRow class="nv-row">
            <template #label>HUD Style</template>
            <BngSelect
              :value="st.navDesign || 'gmaps_card'"
              :options="designOptions"
              :config="selectCfg"
              @valueChanged="val => setDesign(val)"
            />
          </BngRow>

          <BngRow class="nv-row">
            <template #label>Hide 3D World Turn Arrows</template>
            <BngSwitch :modelValue="st.hideWorldMarkers === true" @update:modelValue="val => setHideWorldMarkers(val)" />
          </BngRow>

          <BngRow class="nv-row">
            <template #label>Audio Approach Chimes</template>
            <BngSwitch :modelValue="st.chimeEnabled !== false" @update:modelValue="val => setChimeEnabled(val)" />
          </BngRow>

          <BngRow class="nv-row">
            <template #label>Distance Units</template>
            <BngSelect
              :value="st.units || 'metric'"
              :options="unitOptions"
              :config="selectCfg"
              @valueChanged="val => setUnits(val)"
            />
          </BngRow>

          <BngRow class="nv-row">
            <template #label>North-Up Round Minimap</template>
            <BngSwitch :modelValue="st.northUp === true" @update:modelValue="val => setNorthUp(val)" />
          </BngRow>
        </div>
      </div>
    </BngCard>

    <div v-if="navError" class="nv-note is-err">{{ navError }}</div>
    <div v-else class="nv-note">
      Tracks active GPS destinations, Transport Mode routes, and waypoints — even with 3D world turn arrows disabled.
    </div>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted } from "vue"
import {
  BngCard, BngCardHeading, BngButton, BngSwitch, BngSelect, BngRow, BngPill, ACCENTS,
} from "@/common/components/base"
import {
  navState, navError, start, stop,
  setEnabled, setDesign, cycleDesign, setChimeEnabled, setUnits, setHideWorldMarkers, setNorthUp,
} from "./earthNavStore.js"

onMounted(start)
onUnmounted(stop)

const st = computed(() => navState.value || {})
const selectCfg = { label: x => x.label, value: x => x.value }

const designOptions = [
  {
    value: "gmaps_card",
    label: "Maps Card",
    desc: "High-contrast Google Maps / CarPlay turn banner with motorway exit callout, approach bar, 'Then' preview, and trip footer.",
  },
  {
    value: "round_minimap",
    label: "Round Minimap",
    desc: "Circular BeamNG.Earth road & route minimap topped with a docked compact turn-by-turn header.",
  },
  {
    value: "ets_advisor",
    label: "Route Advisor",
    desc: "Wide dark translucent cockpit bar with compass strip, speed-limit sign badge, next turn/exit, and ETA telemetry.",
  },
]

const unitOptions = [
  { value: "metric", label: "Metric (km / m)" },
  { value: "imperial", label: "Imperial (mi / ft)" },
]

const activeDesignDesc = computed(() => {
  const cur = st.value.navDesign || "gmaps_card"
  const found = designOptions.find(d => d.value === cur)
  return found ? found.desc : designOptions[0].desc
})

function fmtDist(m) {
  const v = Math.max(0, Number(m) || 0)
  if (st.value.units === "imperial") {
    const ft = v * 3.28084
    if (ft < 1000) return `${Math.round(ft / 10) * 10} ft`
    return `${(v / 1609.344).toFixed(1)} mi`
  }
  if (v < 1000) return `${Math.round(v)} m`
  return `${(v / 1000).toFixed(1)} km`
}

const formattedDist = computed(() => fmtDist(st.value.distToTurnM))
const formattedRem = computed(() => fmtDist(st.value.remainingM))
const formattedEta = computed(() => {
  const s = Math.max(0, Math.round(Number(st.value.etaSec) || 0))
  if (s < 60) return "< 1 min"
  const mins = Math.round(s / 60)
  if (mins < 60) return `${mins} min`
  return `${Math.floor(mins / 60)}h ${String(mins % 60).padStart(2, "0")}m`
})
</script>

<style scoped lang="scss">
.nv-root {
  display: flex;
  flex-direction: column;
  gap: 0.55em;
}

.nv-card {
  width: 100%;
}

.nv-pills {
  display: inline-flex;
  gap: 0.35em;
  margin-left: 0.6em;
  vertical-align: middle;
}

.nv-pill-ok {
  --bng-pill-bg: rgba(34, 155, 84, 0.25);
  --bng-pill-color: var(--bng-add-green-300, #7ee2a8);
}

.nv-pill-neutral {
  --bng-pill-bg: rgba(255, 255, 255, 0.1);
  --bng-pill-color: var(--bng-cool-gray-200, #c8ccd4);
}

.nv-body {
  display: flex;
  flex-direction: column;
  gap: 0.75em;
  padding: 0.65em 0.85em 0.85em;
}

.nv-preview {
  display: flex;
  flex-direction: column;
  gap: 0.45em;
  padding: 0.55em 0.65em;
  border-radius: var(--bng-corners-1, 4px);
  background: rgba(var(--bng-ter-blue-gray-900-rgb, 24, 28, 36), 0.55);
  border: 1px solid rgba(255, 255, 255, 0.08);
}

.nv-preview-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5em;
}

.nv-preview-label {
  font-weight: 700;
  font-size: 0.92em;
  color: var(--bng-off-white, #f0f0f0);
}

.nv-designs {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4em;
}

.nv-design-btn {
  flex: 1 1 0;
  min-width: 100px;
}

.nv-design-desc {
  font-size: 0.86em;
  line-height: 1.35;
  color: var(--bng-cool-gray-300, #b4b8c2);
}

.nv-live {
  display: flex;
  flex-direction: column;
  gap: 0.25em;
  padding: 0.55em 0.7em;
  border-radius: var(--bng-corners-1, 4px);
  background: rgba(20, 83, 45, 0.35);
  border-left: 3px solid var(--bng-orange-b400, #ff6600);
}

.nv-live-head {
  display: flex;
  align-items: baseline;
  gap: 0.6em;
}

.nv-live-dist {
  font-weight: 800;
  font-size: 1.15em;
  color: var(--bng-off-white, #ffffff);
}

.nv-live-street {
  font-weight: 700;
  color: var(--bng-off-white, #f0f0f0);
}

.nv-live-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 0.8em;
  font-size: 0.85em;
  color: var(--bng-cool-gray-200, #d0d4dc);
}

.nv-settings {
  display: flex;
  flex-direction: column;
  gap: 0.2em;
}

.nv-num {
  font-variant-numeric: tabular-nums;
}

.nv-note {
  font-size: 0.88em;
  color: var(--bng-cool-gray-300, #b4b8c2);

  &.is-err {
    color: var(--bng-add-red-400, #f88);
  }
}
</style>
