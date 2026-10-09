--[[
    canvas_highlight.lua - Canvas Highlighting & Partial E-ink Refresh Engine
    Project: KOReader TTS Plugin
    Layer: Presentation / UI
--]]

local ok_blit, Blitbuffer = pcall(require, "ffi/blitbuffer")
if not ok_blit or not Blitbuffer then
    Blitbuffer = {
        COLOR_WHITE  = 0xFFFFFF,
        COLOR_BLACK  = 0x000000,
        COLOR_GRAY_E = 0xEEEEEE,
    }
end

local ok_uimanager, UIManager = pcall(require, "ui/uimanager")
if not ok_uimanager then
    UIManager = {}
end

local CanvasHighlight = {}
CanvasHighlight.__index = CanvasHighlight

--- Creates a new CanvasHighlight instance.
function CanvasHighlight:new()
    local instance = setmetatable({}, self)
    instance.current_highlight = nil
    return instance
end

--- Highlights sentence bounding boxes with partial E-ink refresh.
-- @param view Document view object
-- @param bboxes Array of bounding boxes { x, y, w, h }
-- @param mode Highlight mode: "gray" | "underline" | "none"
function CanvasHighlight:highlightSentence(view, bboxes, mode)
    mode = mode or "gray"
    if mode == "none" then
        self:clearHighlight(view)
        return
    end

    if not view then
        return
    end

    -- Collect previous rects to dirty for clean removal
    local dirty_rects = {}
    if self.current_highlight then
        for _, rect in ipairs(self.current_highlight) do
            table.insert(dirty_rects, rect)
        end
    end

    -- Clear old highlight on view
    if type(view.clearHighlight) == "function" then
        pcall(view.clearHighlight, view)
    end

    if not bboxes or #bboxes == 0 then
        self.current_highlight = nil
        if #dirty_rects > 0 and UIManager.setDirty then
            pcall(UIManager.setDirty, UIManager, view, "partial", dirty_rects)
        end
        return
    end

    -- Apply highlight style
    local highlight_boxes = bboxes
    local highlight_color = Blitbuffer.COLOR_GRAY_E

    if mode == "underline" then
        -- Underline style: 2px stripe at bottom of each text line
        highlight_boxes = {}
        for _, b in ipairs(bboxes) do
            table.insert(highlight_boxes, {
                x = b.x,
                y = b.y + math.max(0, b.h - 2),
                w = b.w,
                h = 2,
            })
        end
        highlight_color = Blitbuffer.COLOR_BLACK
    end

    if type(view.setHighlight) == "function" then
        pcall(view.setHighlight, view, highlight_boxes, highlight_color)
    end

    self.current_highlight = highlight_boxes

    -- Add new rects to dirty list
    for _, rect in ipairs(highlight_boxes) do
        table.insert(dirty_rects, rect)
    end

    -- Instruct UIManager to execute partial refresh only (prevents E-ink flashing)
    if #dirty_rects > 0 and UIManager.setDirty then
        pcall(UIManager.setDirty, UIManager, view, "partial", dirty_rects)
    end
end

--- Clears active highlight on view.
-- @param view Document view object
function CanvasHighlight:clearHighlight(view)
    if self.current_highlight and view then
        local old_rects = self.current_highlight
        self.current_highlight = nil

        if type(view.clearHighlight) == "function" then
            pcall(view.clearHighlight, view)
        end
        if UIManager.setDirty then
            pcall(UIManager.setDirty, UIManager, view, "partial", old_rects)
        end
    end
end

return CanvasHighlight
