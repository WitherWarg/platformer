-- breezefield: World.lua
--[[
   World: has access to all the functions of love.physics.world
   additionally stores all Collider objects assigned to it in
   self.colliders (as key-value pairs)
   can draw all its Colliders
   by default, calls :collide on any colliders in it for postSolve
   or for beginContact if the colliders are sensors
--]]
-- TODO make updating work from here too
-- TODO: update test and tutorial
local Collider = require((...):gsub('world', '') .. 'collider')
local set_funcs, lp, lg, COLLIDER_TYPES = unpack(
   require((...):gsub('world', '') .. '/utils'))



local World = {}
World.__index = World
function World:new(...)
   -- create a new physics world
   --[[
      inputs: (same as love.physics.newWorld)
      xg: float, gravity in x direction
      yg: float, gravity in y direction
      sleep: boolean, whether bodies can sleep
      outputs:
      w: bf.World, the created world
   ]]--

   local w = {}
   setmetatable(w, self)
   w._world = lp.newWorld(...)
   set_funcs(w, w._world)
   w.update = nil -- to use our custom update
   w.colliders = {}

   -- some functions defined here to use w without being passed it

   function w.collide(obja, objb, coll_type, ...)
      -- collision event for two Colliders
      local function run_coll(obj1, obj2, ...)
	 if obj1[coll_type] ~= nil then
	    local e = obj1[coll_type](obj1, obj2, ...)
	    if type(e) == 'function' then
	       w.collide_events[#w.collide_events+1] = e
	    end
	 end
      end

      if obja ~= nil and objb ~= nil then
	 run_coll(obja, objb, ...)
	 run_coll(objb, obja, ...)
      end
   end

   function w.enter(a, b, ...)
      return w.collision(a, b, 'enter', ...)
   end
   function w.exit(a, b, ...)
      return w.collision(a, b, 'exit', ...)
   end
   function w.preSolve(a, b, ...)
      return w.collision(a, b, 'preSolve', ...)
   end
   function w.postSolve(a, b, ...)
      return w.collision(a, b, 'postSolve', ...)
   end

   function w.collision(a, b, ...)
      -- objects that hit one another can have collide methods
      -- by default used as postSolve callback
      local obja = a:getUserData(a)
      local objb = b:getUserData(b)
      w.collide(obja, objb, ...)
   end

   w:setCallbacks(w.enter, w.exit, w.preSolve, w.postSolve)
   w.collide_events = {}

   w.collision_classes = {
      default = {category = 1, ignores = {}},
   }

   return w
end

function World:_remove(collider)
   -- remove collider from table of tracked colliders (does NOT run proper destructors)
   --[[
      collider: collider to untrack
   --]]
   for i, col in ipairs(self.colliders) do
      if col == collider then
         table.remove(self.colliders, i)
         break
      end
   end
   self.colliders[collider] = nil
end

function World:draw(alpha, draw_over)
   -- draw the world
   --[[
      alpha: sets the alpha of the drawing, defaults to 1
      draw_over: draws the collision objects shapes even if their
		.draw method is overwritten
   --]]
   local color = {love.graphics.getColor()}
   if self._draw_order_changed then
      table.sort(
         self.colliders,
         function(a, b) return a:getDrawOrder() < b:getDrawOrder() end
	   )
      self._draw_order_changed = false
   end
   for _, c in ipairs(self.colliders) do
      love.graphics.setColor(1, 1, 1, alpha or 1)
      c:draw(alpha)
      if draw_over then
	 love.graphics.setColor(1, 1, 1, alpha or 1)
	 c:__draw__()
      end
   end
   love.graphics.setColor(color)
end

local function filter_query(world, colliders, collision_class)
   if not collision_class then
      return colliders
   end

   local filter_category = world.collision_classes[collision_class].category

   for i = #colliders, 1, -1 do
      local collider = colliders[i]
      local is_removed = true
      for _, category in ipairs({collider:getCategory()}) do
         if category == filter_category then
            is_removed = false
         end
      end

      if is_removed then
         table.remove(colliders, i)
      end
   end

   return colliders
end

function World:queryRectangleArea(x1, y1, x2, y2, collision_class)
   -- query a bounding-box aligned area for colliders
   --[[
      inputs:
      x1, y1, x2, y2: floats, the x and y coordinates of two points
      outputs:
      colls: table, all colliders in bounding box
   --]]

   local colls = {}
   local callback = function(fixture)
      table.insert(colls, fixture:getUserData())
      return true
   end
   self:queryBoundingBox(x1, y1, x2, y2, callback)
   return filter_query(self, colls, collision_class)
end

local function check_vertices(vertices)
   if #vertices % 2 ~= 0 then
      error('vertices must be a multiple of 2')
   elseif #vertices < 4 then
      error('must have at least 2 vertices with x and y each')
   end
end

local function is_edgy(colltype)
   return colltype == COLLIDER_TYPES.POLY
      or colltype == COLLIDER_TYPES.RECT
      or colltype == COLLIDER_TYPES.EDGE
      or colltype == COLLIDER_TYPES.CHAIN
end

local function any_intersections(coll1, coll2)
   local vertices = {coll1:getSpatialIdentity()}
   for i=1,#vertices-3,2 do
      local x1, y1 = vertices[i], vertices[i+1]
      local x2, y2 = vertices[i+2], vertices[i+3]
      if (coll2:rayCast(x1, y1, x2, y2, 1) ~= nil)
	 or coll2:testPoint(x1, y1)
	 or coll2:testPoint(x2, y2)
      then
	 return true
      end
   end
end

local function poly_circle_intersect(poly, circle)
   if any_intersections(poly, circle) then
      return true
   end
   return poly:testPoint(circle:getPosition())
      or circle:testPoint(poly:getMassData())
end

local function poly_poly_intersect(poly1, poly2)
   return any_intersections(poly1, poly2)
      or any_intersections(poly2, poly1)
      or poly1:testPoint(poly2:getMassData()) -- poly2 in poly1
      or poly2:testPoint(poly2:getMassData()) -- poly1 in poly2
end

local function are_touching(coll1, coll2)
   if coll1.collider_type == COLLIDER_TYPES.CIRCLE and is_edgy(coll2.collider_type) then
      return are_touching(coll2, coll1)
   end
   if is_edgy(coll1.collider_type) and coll2.collider_type == COLLIDER_TYPES.CIRCLE then
      return poly_circle_intersect(coll1, coll2)
   end
   if is_edgy(coll1.collider_type) and is_edgy(coll2.collider_type) then
      return poly_poly_intersect(coll1, coll2)
   end
   if coll1.collider_type == COLLIDER_TYPES.CIRCLE and coll2.collider_type == COLLIDER_TYPES.CIRCLE then
      return ((coll1:getX() - coll2:getX())^2 + (coll1:getY() - coll2:getY())) <=
	 coll1:getRadius() + coll2:getRadius()
   end
   error("collider types not recognized ".. tostring(coll1.collider_type)..', '..tostring(coll2.collider_type))
end

local function query_region(world, coll_type, args, collision_class)
   local collider = world:newCollider(coll_type, args)
   collider:setSensor(true)
   local colls = {}
   local function callback(fixture)
      local coll = fixture:getUserData()
      if coll ~= collider then
	 if are_touching(collider, coll) then
	    table.insert(colls, coll)
	 end
      end
      return true
   end
   local ax, ay, bx, by = collider:getBoundingBox()
   local in_bounding_box = world:queryBoundingBox(
      ax, ay, bx, by, callback)
   collider:destroy()
   return filter_query(world, colls, collision_class)
end

function World:_disable_callbacks()
   self._callbacks = {self._world:getCallbacks()}
   self._world:setCallbacks()
end

function World:_enable_callbacks()
   self._world:setCallbacks(unpack(self._callbacks))
end

function World:queryPolygonArea(...)
   -- query an area enclosed by the lines connecting a series of points
   --[[
      inputs:
        x1, y1, x2, y2, ... floats, the x and y positions defining polygon
      outputs:
        colls: table, all Colliders intersecting the area
   --]]
   local vertices = {...}
   if type(vertices[#vertices]) == 'string' then
      collision_class = vertices[#vertices]
      table.remove(vertices, #vertices)
   end
   if type(vertices[1]) == 'table' then
      vertices = vertices[1]
   end

   check_vertices(vertices)
   return query_region(self, COLLIDER_TYPES.POLYGON, vertices, collision_class)
end

function World:queryCircleArea(x, y, r, collision_class)
   -- get all colliders in a circle are
   --[[
      inputs:
        x, y, r: floats, x, y and radius of circle
      outputs:
        colls: table: colliders in area
   ]]--
   return query_region(self, COLLIDER_TYPES.CIRCLE, {x, y, r}, collision_class)
end

function World:queryEdgeArea(...)
   -- get all colliders along a (series of) line(s)
   --[[
      inputs:
        x1, y1, x2, y2, ... floats, the x and y positions defining lines
       outpts:
        colls: table: colliders intersecting these lines
   --]]
   local vertices = {...}
   if type(vertices[#vertices]) == 'string' then
      collision_class = vertices[#vertices]
      table.remove(vertices, #vertices)
   end
   if type(vertices[1]) == 'table' then
      vertices = vertices[1]
   end

   check_vertices(vertices)
   return query_region(self, 'Edge', vertices, collision_class)
end

function World:update(dt)
   -- update physics world
   self._world:update(dt)
   for i, v in pairs(self.collide_events) do
      v()
      self.collide_events[i] = nil
   end
end

--[[
create a new collider in this world

args:
   collider_type (string): the type of the collider (not case seinsitive). any of:
      circle, rectangle, polygon, edge, chain.
   shape_arguments (table): arguments required to instantiate shape.
      circle: {x, y, radius}
      rectangle: {x, y, width height}
      polygon/edge/chain: {x1, y1, x2, y2, ...}
   table_to_use (optional, table): table to generate as the collider
]]--
function World:newCollider(collider_type, shape_arguments, table_to_use)
   local o = table_to_use or {}
   setmetatable(o, Collider)
   -- note that you will need to set static vs dynamic later
   local _collider_type = COLLIDER_TYPES[collider_type:upper()]
   assert(_collider_type ~= nil, "unknown collider type: "..collider_type)
   collider_type = _collider_type
   if collider_type == COLLIDER_TYPES.CIRCLE then
      local x, y, r = unpack(shape_arguments)
      o.body = lp.newBody(self._world, x, y, "dynamic")
      o.shape = lp.newCircleShape(r)
   elseif collider_type == "Rectangle" then
      local x, y, w, h = unpack(shape_arguments)
      o.body = lp.newBody(self._world, x, y, "dynamic")
      o.shape = lp.newRectangleShape(w, h)
      collider_type = "Polygon"
   else
      o.body = lp.newBody(self._world, 0, 0, "dynamic")
      o.shape = lp['new'..collider_type..'Shape'](unpack(shape_arguments))
   end
   
   o.collider_type = collider_type

   o.fixture = lp.newFixture(o.body, o.shape, 1)
   o.fixture:setUserData(o)

   set_funcs(o, o.body)
   set_funcs(o, o.shape)
   set_funcs(o, o.fixture)

   o.fixture:setUserData(o)

   o.normals = {}

   -- index by self for now
   o._world = self
   table.insert(self.colliders, o)
   self.colliders[o] = o
   o:setDrawOrder(0)
   return o
end

function World:addCollisionClasses(...)
   for _, collision_class in pairs({...}) do
      assert(type(collision_class) == 'table', 'All collision classes must be a table (see World:addCollisionClasses)')
      self:addCollisionClass(collision_class)
  end
end

function World:addCollisionClass(collision_class)
   local category_number = 0
    for _, _ in pairs(self.collision_classes) do
        category_number = category_number + 1
    end

   self.collision_classes[collision_class[1]:lower()] = {
      category = category_number + 1,
      ignores = collision_class.ignores or {}
   }
end

function World:setCollisionClasses(collider, ...)
   assert(type(self) == 'table', "Collider must be provided as the first argument.")
   
   local collision_classes = {...}
   assert(#collision_classes > 0, "Must provide at least one collision class")

   for i, collision_class1 in ipairs(collision_classes) do
      for j, collision_class2 in ipairs(collision_classes) do
         assert(collision_class1 ~= collision_class2 or i == j, "Cannot provide the same collision class")
      end
   end

   local categories = {}
   local list_of_ignores = {}
   for _, collision_class in ipairs(collision_classes) do   
      assert(
         self.collision_classes[collision_class:lower()] ~= nil,
         "Collision class " .. collision_class  .. " is not defined (see World:addCollisionClass)"
      )

      collision_class = self.collision_classes[collision_class:lower()]

      table.insert(categories, collision_class.category)
      table.insert(list_of_ignores, collision_class.ignores)
   end

   collider:setCategory(unpack(categories))
   
   local masks = {}
   for _, ignores in ipairs(list_of_ignores) do
      for _, collision_class in ipairs(ignores) do
         assert(
            self.collision_classes[collision_class:lower()] ~= nil,
            "Collision class " .. collision_class .. " is not defined (see World:addCollisionClass)"
         )
         table.insert(masks, self.collision_classes[collision_class:lower()].category)
      end
   end

   collider:setMask(unpack(masks))
end

return World