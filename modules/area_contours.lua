PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Contours = {}

PC.AreaContours = Contours

-- This renderer is adapted from unrealQuest's area-contour system. Coordinates
-- are percentages in the currently viewed zone (0..100 on both axes).
local GRID = 800
local MAP_SIZE = 100
local Y_SCALE = 2 / 3
local HULL_PADDING = 0.85
local PROFILE_SIZE = 256
local PROFILE_D_MIN = -1.22
local PROFILE_D_MAX = 0.94
local PROFILE_TOLERANCE = 0.06
local CORNER_RADIUS = 0.85
local CORNER_EDGE_RATIO = 0.20
local CORNER_SEGMENTS = 3
local STRAIGHT_CORNER_COSINE = -0.985

Contours.GRID = GRID
Contours.BUILD_ROWS_PER_TICK = 8
Contours.GEOMETRY = {
  version = "uc-poi-shapes-v4",
  mapSize = MAP_SIZE,
  yScale = Y_SCALE,
  hullPadding = HULL_PADDING,
  singlePolygon = true,
  verticesExact = true,
  controlVertices = true,
  controlVerticesMapped = true,
  controlVertexLimit = 32,
  cornerRadius = CORNER_RADIUS,
  cornerEdgeRatio = CORNER_EDGE_RATIO,
  cornerSegments = CORNER_SEGMENTS,
  straightCornerCosine = STRAIGHT_CORNER_COSINE,
  circleNative = true,
}

local function SpanOrder(a, b)
  return a[1] < b[1]
end

local function PointOrder(a, b)
  if a[1] == b[1] then return a[2] < b[2] end
  return a[1] < b[1]
end

local function Clamp(value, minimum, maximum)
  if value < minimum then return minimum end
  if value > maximum then return maximum end
  return value
end

local function UniquePoints(locations)
  local points = {}
  local seen = {}
  local index = 1
  local total = table.getn(locations or {})
  while index <= total do
    local location = locations[index]
    local x = location and (location.x or location[1])
    local y = location and (location.y or location[2])
    if type(x) == "number" and type(y) == "number"
        and x >= 0 and x <= MAP_SIZE and y >= 0 and y <= MAP_SIZE then
      local key = tostring(x) .. ":" .. tostring(y)
      if not seen[key] then
        seen[key] = true
        table.insert(points, { x, y })
      end
    end
    index = index + 1
  end
  table.sort(points, PointOrder)
  return points
end

local function OrderedPoints(locations)
  local points = {}
  local index = 1
  local total = table.getn(locations or {})
  while index <= total do
    local location = locations[index]
    local x = location and (location.x or location[1])
    local y = location and (location.y or location[2])
    if type(x) == "number" and type(y) == "number"
        and x >= 0 and x <= MAP_SIZE and y >= 0 and y <= MAP_SIZE then
      table.insert(points, { x, y })
    end
    index = index + 1
  end
  return points
end

local function Cross(origin, a, b)
  return (a[1] - origin[1]) * (b[2] - origin[2])
    - (a[2] - origin[2]) * (b[1] - origin[1])
end

local function ConvexHull(points)
  table.sort(points, PointOrder)
  local lower = {}
  local index = 1
  local total = table.getn(points)
  while index <= total do
    local point = points[index]
    while table.getn(lower) > 1
        and Cross(lower[table.getn(lower) - 1], lower[table.getn(lower)], point) <= 0 do
      table.remove(lower)
    end
    table.insert(lower, point)
    index = index + 1
  end

  local upper = {}
  index = total
  while index >= 1 do
    local point = points[index]
    while table.getn(upper) > 1
        and Cross(upper[table.getn(upper) - 1], upper[table.getn(upper)], point) <= 0 do
      table.remove(upper)
    end
    table.insert(upper, point)
    index = index - 1
  end

  local hull = {}
  index = 1
  while index < table.getn(lower) do
    table.insert(hull, lower[index])
    index = index + 1
  end
  index = 1
  while index < table.getn(upper) do
    table.insert(hull, upper[index])
    index = index + 1
  end
  return hull
end

local function ExpandedPolygon(group, padding)
  local expanded = {}
  local pointIndex = 1
  local pointTotal = table.getn(group)
  while pointIndex <= pointTotal do
    local point = group[pointIndex]
    local offsetIndex = 1
    while offsetIndex <= 8 do
      local angle = (offsetIndex - 1) * math.pi / 4
      table.insert(expanded, {
        Clamp(point[1] + math.cos(angle) * padding, 0, MAP_SIZE),
        Clamp(point[2] + math.sin(angle) * padding / Y_SCALE, 0, MAP_SIZE),
      })
      offsetIndex = offsetIndex + 1
    end
    pointIndex = pointIndex + 1
  end
  return ConvexHull(expanded)
end

local function SegmentDistanceSquared(px, py, edge)
  local ax, ay = edge[1], edge[2]
  local dx, dy = edge[3] - ax, edge[4] - ay
  local lengthSquared = dx * dx + dy * dy
  local amount = 0
  if lengthSquared > 0 then
    amount = ((px - ax) * dx + (py - ay) * dy) / lengthSquared
    if amount < 0 then amount = 0 elseif amount > 1 then amount = 1 end
  end
  local ex = ax + dx * amount - px
  local ey = ay + dy * amount - py
  return ex * ex + ey * ey
end

local function IsoPolygon(polygon, reach)
  local cellPercent = MAP_SIZE / GRID
  local rows = {}
  local minY, maxY = nil, nil
  local total = table.getn(polygon)
  local index = 1
  while index <= total do
    local a = polygon[index]
    local b = polygon[index < total and index + 1 or 1]
    local edge = {
      a[1] / cellPercent, a[2] / cellPercent * Y_SCALE,
      b[1] / cellPercent, b[2] / cellPercent * Y_SCALE,
    }
    local low, high = edge[2], edge[4]
    if low > high then low, high = high, low end
    if not minY or low < minY then minY = low end
    if not maxY or high > maxY then maxY = high end
    local row = math.max(0, math.floor((low - reach) / Y_SCALE - 0.5))
    local last = math.min(GRID - 1, math.ceil((high + reach) / Y_SCALE - 0.5))
    while row <= last do
      rows[row] = rows[row] or {}
      table.insert(rows[row], edge)
      row = row + 1
    end
    index = index + 1
  end
  return { rows = rows, minY = minY, maxY = maxY }
end

local function RowReach(near, y, reach, ranges)
  local left, right = nil, nil
  local index = 1
  local total = table.getn(near)
  while index <= total do
    local edge = near[index]
    local ay, by = edge[2], edge[4]
    if (ay > y) ~= (by > y) then
      local x = edge[1] + (y - ay) * (edge[3] - edge[1]) / (by - ay)
      if not left or x < left then left = x end
      if not right or x > right then right = x end
    end
    local low, high = ay, by
    if low > high then low, high = high, low end
    if high >= y - reach and low <= y + reach then
      local x1, x2 = edge[1], edge[3]
      if high > low then
        local slope = (edge[3] - edge[1]) / (by - ay)
        x1 = edge[1] + (math.max(low, y - reach) - ay) * slope
        x2 = edge[1] + (math.min(high, y + reach) - ay) * slope
      end
      if x1 > x2 then x1, x2 = x2, x1 end
      table.insert(ranges, {
        math.floor(x1 - reach - 0.5), math.ceil(x2 + reach - 0.5),
      })
    end
    index = index + 1
  end
  return left, right
end

local function MergeRanges(ranges)
  table.sort(ranges, SpanOrder)
  local merged = {}
  local index = 1
  local total = table.getn(ranges)
  while index <= total do
    local range = ranges[index]
    local previous = merged[table.getn(merged)]
    if previous and range[1] <= previous[2] + 1 then
      if range[2] > previous[2] then previous[2] = range[2] end
    else
      table.insert(merged, { range[1], range[2] })
    end
    index = index + 1
  end
  return merged
end

local function LinearPieces(values, count, firstX, pieces)
  local start = 1
  while start <= count do
    if values[start] <= PROFILE_D_MIN then
      start = start + 1
    else
      local origin = values[start]
      local low, high = -1000000, 1000000
      local finish = start
      while finish + 1 <= count and values[finish + 1] > PROFILE_D_MIN do
        local offset = finish + 1 - start
        local value = values[finish + 1]
        local nextLow = (value - PROFILE_TOLERANCE - origin) / offset
        local nextHigh = (value + PROFILE_TOLERANCE - origin) / offset
        if nextLow < low then nextLow = low end
        if nextHigh > high then nextHigh = high end
        if nextLow > nextHigh then break end
        low, high = nextLow, nextHigh
        finish = finish + 1
      end
      local slope = 0
      if finish > start then slope = (low + high) / 2 end
      local leftValue = Clamp(origin - slope * 0.5, PROFILE_D_MIN, PROFILE_D_MAX)
      local rightValue = Clamp(origin + slope * (finish - start + 0.5),
        PROFILE_D_MIN, PROFILE_D_MAX)
      table.insert(pieces, {
        firstX + start - 1, firstX + finish, leftValue, rightValue,
      })
      start = finish + 1
    end
  end
end

local function CirclePoints(shape)
  local points = {}
  if type(shape) ~= "table" or shape.type ~= "circle"
      or type(shape.x) ~= "number" or type(shape.y) ~= "number"
      or type(shape.radius) ~= "number" or shape.radius <= 0 then
    return points
  end
  local index = 0
  while index < 48 do
    local angle = index / 48 * math.pi * 2
    table.insert(points, {
      Clamp(shape.x + math.cos(angle) * shape.radius, 0, MAP_SIZE),
      Clamp(shape.y + math.sin(angle) * shape.radius / Y_SCALE, 0, MAP_SIZE),
    })
    index = index + 1
  end
  return points
end

local function SmoothControlPolygon(controlVertices)
  local controls = OrderedPoints(controlVertices)
  local total = table.getn(controls)
  if total < 3 then return {} end
  local points = {}
  local index = 1
  while index <= total do
    local previous = controls[index > 1 and index - 1 or total]
    local current = controls[index]
    local following = controls[index < total and index + 1 or 1]
    local previousX = previous[1] - current[1]
    local previousY = (previous[2] - current[2]) * Y_SCALE
    local followingX = following[1] - current[1]
    local followingY = (following[2] - current[2]) * Y_SCALE
    local previousLength = math.sqrt(previousX * previousX + previousY * previousY)
    local followingLength = math.sqrt(followingX * followingX + followingY * followingY)
    if previousLength == 0 or followingLength == 0 then
      table.insert(points, { current[1], current[2] })
    else
      local cosine = (previousX * followingX + previousY * followingY)
        / (previousLength * followingLength)
      if cosine <= STRAIGHT_CORNER_COSINE then
        table.insert(points, { current[1], current[2] })
      else
        local radius = math.min(
          CORNER_RADIUS,
          previousLength * CORNER_EDGE_RATIO,
          followingLength * CORNER_EDGE_RATIO)
        local incomingX = current[1] + previousX / previousLength * radius
        local incomingY = current[2] + previousY / previousLength * radius / Y_SCALE
        local outgoingX = current[1] + followingX / followingLength * radius
        local outgoingY = current[2] + followingY / followingLength * radius / Y_SCALE
        local step = 0
        while step <= CORNER_SEGMENTS do
          local amount = step / CORNER_SEGMENTS
          local inverse = 1 - amount
          table.insert(points, {
            Clamp(inverse * inverse * incomingX
              + 2 * inverse * amount * current[1]
              + amount * amount * outgoingX, 0, MAP_SIZE),
            Clamp(inverse * inverse * incomingY
              + 2 * inverse * amount * current[2]
              + amount * amount * outgoingY, 0, MAP_SIZE),
          })
          step = step + 1
        end
      end
    end
    index = index + 1
  end
  return points
end

function Contours.ShapePolygons(locations, vertices, padding, shape, controlVertices)
  local circle = CirclePoints(shape)
  if table.getn(circle) >= 3 then return { circle } end
  local mapped = SmoothControlPolygon(controlVertices)
  if table.getn(mapped) >= 3 then return { mapped } end
  local explicit = OrderedPoints(vertices)
  if table.getn(explicit) >= 3 then return { explicit } end

  local points = UniquePoints(locations)
  if table.getn(points) > 0 then
    return { ExpandedPolygon(points, padding or HULL_PADDING) }
  end
  return {}
end

local function PointInPolygon(x, y, polygon)
  local inside = false
  local index = 1
  local previous = table.getn(polygon)
  while index <= table.getn(polygon) do
    local a = polygon[index]
    local b = polygon[previous]
    if (a[2] > y) ~= (b[2] > y)
        and x < (b[1] - a[1]) * (y - a[2]) / (b[2] - a[2]) + a[1] then
      inside = not inside
    end
    previous = index
    index = index + 1
  end
  return inside
end

function Contours.ContainsPoint(locations, x, y, vertices, padding, shape, controlVertices)
  if type(x) ~= "number" or type(y) ~= "number" then return false end
  local polygons = Contours.ShapePolygons(
    locations, vertices, padding, shape, controlVertices)
  local index = 1
  while index <= table.getn(polygons) do
    if PointInPolygon(x, y, polygons[index]) then return true end
    index = index + 1
  end
  return false
end

-- Presence and map hover test the same areas several times a second. The
-- polygons are built once per registered area (areas are never edited in
-- place), so the hit test allocates nothing on 1.12's stop-the-world GC.
function Contours.AreaContainsPoint(area, x, y)
  if type(area) ~= "table" or type(x) ~= "number" or type(y) ~= "number" then return false end
  local polygons = area.hitPolygons
  if not polygons then
    polygons = Contours.ShapePolygons(
      area.locations, area.vertices, nil, area.shape, area.controlVertices)
    area.hitPolygons = polygons
  end
  local index = 1
  while index <= table.getn(polygons) do
    if PointInPolygon(x, y, polygons[index]) then return true end
    index = index + 1
  end
  return false
end

local function BuildPolygons(locations, vertices, padding, reach, shape, controlVertices)
  local polygons = {}
  local shapes = Contours.ShapePolygons(
    locations, vertices, padding, shape, controlVertices)
  local index = 1
  while index <= table.getn(shapes) do
    table.insert(polygons, IsoPolygon(shapes[index], reach or 0))
    index = index + 1
  end
  return polygons
end

function Contours.BeginBuild(locations, vertices, shape, controlVertices)
  local patches = {}
  local reach = -PROFILE_D_MIN + 0.01
  local polygons = BuildPolygons(
    locations, vertices, HULL_PADDING, reach, shape, controlVertices)
  local polygonTotal = table.getn(polygons)
  if polygonTotal == 0 then
    return { patches = patches, done = true }
  end

  local minY, maxY = nil, nil
  local index = 1
  while index <= polygonTotal do
    local polygon = polygons[index]
    if not minY or polygon.minY < minY then minY = polygon.minY end
    if not maxY or polygon.maxY > maxY then maxY = polygon.maxY end
    index = index + 1
  end

  return {
    patches = patches,
    reach = reach,
    polygons = polygons,
    polygonTotal = polygonTotal,
    active = {},
    row = math.max(0, math.floor((minY - reach) / Y_SCALE - 0.5)),
    lastRow = math.min(GRID - 1, math.ceil((maxY + reach) / Y_SCALE - 0.5)),
    done = false,
  }
end

function Contours.StepBuild(build, rowBudget)
  if not build or build.done then
    return true, build and build.patches or {}
  end

  local processed = 0
  while build.row <= build.lastRow and processed < (rowBudget or Contours.BUILD_ROWS_PER_TICK) do
    local row = build.row
    local y = (row + 0.5) * Y_SCALE
    local lefts, rights, nears = {}, {}, {}
    local bandRanges, cellRanges = {}, {}
    local index = 1
    while index <= build.polygonTotal do
      local near = build.polygons[index].rows[row]
      nears[index] = near
      if near then
        local left, right = RowReach(near, y, build.reach, bandRanges)
        lefts[index], rights[index] = left, right
        if left then
          table.insert(cellRanges, {
            math.ceil(left - 0.5), math.floor(right - 0.5),
          })
        end
      end
      index = index + 1
    end

    bandRanges = MergeRanges(bandRanges)
    local rangeIndex = 1
    while rangeIndex <= table.getn(bandRanges) do
      table.insert(cellRanges, bandRanges[rangeIndex])
      rangeIndex = rangeIndex + 1
    end
    cellRanges = MergeRanges(cellRanges)

    local pieces = {}
    local bandIndex = 1
    rangeIndex = 1
    while rangeIndex <= table.getn(cellRanges) do
      local range = cellRanges[rangeIndex]
      local firstX = math.max(0, range[1])
      local last = math.min(GRID - 1, range[2])
      local values = {}
      local count = 0
      local x = firstX
      while x <= last do
        while bandRanges[bandIndex] and bandRanges[bandIndex][2] < x do
          bandIndex = bandIndex + 1
        end
        local band = bandRanges[bandIndex]
        local value = PROFILE_D_MAX
        if band and x >= band[1] then
          local centre = x + 0.5
          local distance = nil
          local polygonIndex = 1
          while polygonIndex <= build.polygonTotal do
            local near = nears[polygonIndex]
            if near then
              local nearest = (PROFILE_D_MAX + build.reach)
                * (PROFILE_D_MAX + build.reach)
              local edgeIndex = 1
              local edgeTotal = table.getn(near)
              while edgeIndex <= edgeTotal do
                local candidate = SegmentDistanceSquared(centre, y, near[edgeIndex])
                if candidate < nearest then nearest = candidate end
                edgeIndex = edgeIndex + 1
              end
              nearest = math.sqrt(nearest)
              local inside = lefts[polygonIndex] and centre >= lefts[polygonIndex]
                and centre <= rights[polygonIndex]
              local signed = inside and nearest or -nearest
              if not distance or signed > distance then distance = signed end
            end
            polygonIndex = polygonIndex + 1
          end
          value = Clamp(distance or PROFILE_D_MIN, PROFILE_D_MIN, PROFILE_D_MAX)
        end
        count = count + 1
        values[count] = value
        x = x + 1
      end
      LinearPieces(values, count, firstX, pieces)
      rangeIndex = rangeIndex + 1
    end

    local nextActive = {}
    local pieceIndex = 1
    while pieceIndex <= table.getn(pieces) do
      local piece = pieces[pieceIndex]
      local key = piece[1] .. ":" .. piece[2] .. ":"
        .. math.floor(piece[3] * 1000 + 0.5) .. ":"
        .. math.floor(piece[4] * 1000 + 0.5)
      local patch = build.active[key]
      if patch then
        patch[4] = row + 1
      else
        patch = { piece[1], row, piece[2], row + 1, piece[3], piece[4] }
        table.insert(build.patches, patch)
      end
      nextActive[key] = patch
      pieceIndex = pieceIndex + 1
    end
    build.active = nextActive
    build.row = row + 1
    processed = processed + 1
  end

  if build.row > build.lastRow then build.done = true end
  return build.done, build.patches
end

function Contours.ProfileU(distance)
  local amount = (distance - PROFILE_D_MIN) / (PROFILE_D_MAX - PROFILE_D_MIN)
  return (0.5 + Clamp(amount, 0, 1) * (PROFILE_SIZE - 1)) / PROFILE_SIZE
end
