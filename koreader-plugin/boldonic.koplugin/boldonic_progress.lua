-- Waiting dialog while a book is converted. NO progress bar: boldifying a
-- whole EPUB via libarchive is unpaced and finishes too fast for e-ink to
-- show anything, so any bar would just sit at 0% then jump straight to done.
-- Shows the book, the destination and a plain "… please wait" line; update()
-- is inert (progress never paints).

local _ = require("gettext")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local WaitingDialog = InputContainer:extend{
    modal = true,
    dismissable = false,
    alignment = "center",
    book = nil,
    target = nil,
}

function WaitingDialog:init()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local sw = Device.screen:getWidth()
    local content_w = math.min(sw - sc(70), sc(480))
    local inner_w = content_w - sc(44)

    local book_line = TextWidget:new{
        text = self.book or "?",
        face = Font:getFace("cfont", 18),
        bold = true,
        max_width = inner_w,
    }
    local target_txt = (self.target and self.target.folder) or "?"
    local target_line = TextWidget:new{
        text = target_txt,
        face = Font:getFace("smallinfofont"),
        max_width = inner_w,
    }

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
        padding = Size.padding.default,
        VerticalGroup:new{
            align = "left",
            TextWidget:new{
                text = _("Converting in Boldonic"),
                face = Font:getFace("smallinfofontbold"),
                bold = true,
            },
            VerticalSpan:new{ width = sc(6) },
            book_line,
            VerticalSpan:new{ width = sc(2) },
            target_line,
            VerticalSpan:new{ width = sc(14) },
            TextBoxWidget:new{
                text = _("… please wait\n\nThe bolded copy is being written to your card."),
                face = Font:getFace("smallinfofont"),
                width = inner_w,
            },
        },
    }

    self.movable = MovableContainer:new{
        frame,
        unmovable = false,
    }
    self[1] = CenterContainer:new{
        dimen = Device.screen:getSize(),
        self.movable,
    }

    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
end

-- Inert: the conversion is unpaced and finishes too fast for e-ink to show
-- anything, so there is nothing to repaint mid-flight.
function WaitingDialog:update(pct, sent, total, elapsed)
    return true
end

function WaitingDialog:onBack()
    return true
end

local BoldonicProgress = {}

function BoldonicProgress.new(book, target)
    local dlg = WaitingDialog:new{ book = book, target = target }
    UIManager:show(dlg)
    return dlg
end

return BoldonicProgress