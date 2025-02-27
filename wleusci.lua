-- 带科学计数法的版本，注意，一开始科学计数法是不开启的，你需要证明你的实力，达到几千MAX的发电才能开启（可能是4096或者16384，我也算不清楚）
-- 又或者你在代码里面手动把 sciGTInfoOn 的初始值设置为 true

local component = require("component")
local gtm = component.gt_machine
local term = require("term")
local gpu = component.gpu
local colors = require("colors")
local event = require("event")
local thread = require("thread")


local function getWirelessEU()
    local WirelessEUInfo = gtm.getSensorInformation()[23]
    -- 增强的解析函数，用于从文本中提取"Total wireless EU"的值，并忽略颜色代码或其他非数字符号
    local function getEU(text)
        -- 使用改进后的正则表达式匹配"Total wireless EU"的值，忽略颜色代码或其他非数字符号
        local match = string.match(text, "Total wireless EU:%s*[^%d%.]*([%d,%.]+)")
        if match then
            local cleanMatch=string.gsub(match,",","")
            return tonumber(cleanMatch)  -- 将匹配到的字符串转换为数值
        else
            return nil
        end
    end
    return getEU(WirelessEUInfo)
end

-- 存储多少秒的数据
local SECOND_DATA_SIZE = 3600
-- 每60秒存储一次分钟数据，分钟数据的上限
local MINUTE_DATA_SIZE = 4320
-- MAX电压的大小
local maxVoltageValue = 2147483640
-- GT功率显示会往下显示几个电压等级，方便计算
local GT_SHOW_LOWER = 4

local EU_Monitor = {
    secondEU = {},     -- 存储每秒的EU
    minuteEU = {},    -- 存储每分钟的EU
    secondCounter = 0,
    voltageNamesNoColor = {
        "ULV", "LV", "MV", "HV", "EV", "IV", 
        "LUV", "ZPM", "UV", "UHV", "UEV", "UIV", "UMV","UXV"
    },
    maxVoltageNameNoColor = "MAX",
    voltageNames = {},
    maxVoltageName = ""
}
-- sciGTInfoOn 的初始值
local sciGTInfoOn = false
-- local sciGTInfoOn = true
-- 将数值转换为科学计数法格式 123x10^123
local function formatScientific7(value)
    if value == 0 then return "0" end

    local sign = value < 0 and "-" or ""
    value = math.abs(value)

    local exponent = math.floor(math.log(value) / math.log(10))
    local mantissa = value / (10 ^ exponent)

    -- 这里保留了7位小数
    return string.format("%s%.7fx10^%d", sign, mantissa, exponent)
end

-- 将数值转换为科学计数法格式 123x10^123
local function formatScientific2(value)
    if value == 0 then return "0" end

    local sign = value < 0 and "-" or ""
    value = math.abs(value)

    local exponent = math.floor(math.log(value) / math.log(10))
    local mantissa = value / (10 ^ exponent)

    -- 这里保留了2位小数
    return string.format("%s%.2fx10^%d", sign, mantissa, exponent)
end

local function ifformatScientific7(value)
    if sciGTInfoOn then
        return formatScientific7(value)
    else
        return string.format("%.0f",value)
    end
end

local function ifformatScientific2(value)
    if sciGTInfoOn then
        return formatScientific2(value)
    else
        return string.format("%.0f",value)
    end
end
 

-- 设置各种前景色
local voltageNameColorCode = "\27[35m"
local resetColor = "\27[37m"
local greenColor = "\27[32m"
local redColor = "\27[31m"

for i, str in ipairs(EU_Monitor.voltageNamesNoColor) do
    local coloredStr = voltageNameColorCode .. str .. resetColor
    table.insert(EU_Monitor.voltageNames, coloredStr)
end
EU_Monitor.maxVoltageName = voltageNameColorCode .. EU_Monitor.maxVoltageNameNoColor .. resetColor

-- 设置前景色并打印消息
local function toColorString(value)
    if value == 0 then
        return "0"
    end
    local colorCode = value < 0 and greenColor or redColor  -- 绿色或红色
    -- 中式炒股色，如果你需要其他配置，请自行查询“ANSI转义序列颜色代码”，注意oc只支持八色系统

    return colorCode..ifformatScientific7(value)..resetColor
end



-- 计算GT功率信息
local function getGTInfo(euPerTick)
    if euPerTick == 0 then return "0A "..EU_Monitor.voltageNames[1] end

    local absValue = math.abs(euPerTick)
    local voltage_for_tier = absValue / 2 / (4 ^ GT_SHOW_LOWER)

    -- 处理超级超级高的情况
    if sciGTInfoOn then
        return string.format("%s A "..EU_Monitor.maxVoltageName, formatScientific2(absValue/maxVoltageValue))
    end

    -- 处理MAX电压特殊情况
    if absValue >= maxVoltageValue then
        return string.format("%.0fA "..EU_Monitor.maxVoltageName, absValue/maxVoltageValue)
    end

    -- 计算电压等级
    local tier = voltage_for_tier < 4 and 1 or math.floor(math.log(voltage_for_tier) / math.log(4))
    tier = math.max(1, math.min(tier, #EU_Monitor.voltageNames))

    -- 处理超出命名范围的情况
    if tier > #EU_Monitor.voltageNames then
        return string.format("%.0fA "..EU_Monitor.maxVoltageName, absValue/maxVoltageValue)
    end

    -- 计算电流值和电压名称
    local baseVoltage = 8 * (4 ^ (tier - 1))
    local current = absValue / baseVoltage
    return string.format("%.0fA %s", current, EU_Monitor.voltageNames[tier])
end
-- 每秒钟的帧数
local TickPerSecond = 20
-- 计算最后 n 条记录的差值并且得到之间的变化量的平均值（不计入时间间隔，单纯把一前一后两个数的差值除以条目数，请在之后自行除以时间间隔）
local function calculateAverage(data, n)
    local count = math.min(n, #data)
    if count == 0 then return 0 end
    local now = data[1]
    local prev = data[count]
    return (now-prev) / count
end

-- local outputData = {
--     currentEU = 0,
--     fiveSecAvg = 0,
--     minuteAvg = 0,
--     fiveMinAvg = 0,
--     hourAvg = 0
-- }




-- 更新监控数据
function EU_Monitor.update()
    local currentEU = getWirelessEU()

    -- 让出控制
    os.sleep(0)

    -- 每秒钟存一个值
    table.insert(EU_Monitor.secondEU, 1, currentEU)
    if #EU_Monitor.secondEU > SECOND_DATA_SIZE then 
        table.remove(EU_Monitor.secondEU) 
    end

    -- 让出控制
    os.sleep(0)

    -- 每分钟存一个值
    EU_Monitor.secondCounter = EU_Monitor.secondCounter + 1
    if EU_Monitor.secondCounter >= 60 then
        table.insert(EU_Monitor.minuteEU, 1, currentEU)
        if #EU_Monitor.minuteEU > MINUTE_DATA_SIZE then 
            table.remove(EU_Monitor.minuteEU) 
        end
        EU_Monitor.secondCounter = 0
    end

    -- 准备输出数据
    local currentEU = currentEU
    local fiveSecAvg = calculateAverage(EU_Monitor.secondEU, 5)/20
    local minuteAvg = calculateAverage(EU_Monitor.secondEU, 60)/20
    local fiveMinAvg = calculateAverage(EU_Monitor.secondEU, 300)/20
    local hourAvg = calculateAverage(EU_Monitor.secondEU, 3600)/20
    local dayAvg
    if #EU_Monitor.minuteEU < 60 then
        dayAvg = hourAvg
    else
        dayAvg = calculateAverage(EU_Monitor.minuteEU, 1440)/60/20
    end

    -- 处理超级超级高的情况
    if fiveSecAvg >= maxVoltageValue * (4 ^ (GT_SHOW_LOWER + 1)) then
        sciGTInfoOn = true
    end

    -- 让出控制
    os.sleep(0)

    -- 生成输出结果
    term.clear() -- 清除屏幕重新渲染
    
    print(string.format("存量:         %s EU", ifformatScientific7(currentEU), getGTInfo(currentEU/20)))
    print(string.format("可用功率(秒): %s EU/s (%s)", ifformatScientific7(currentEU/20), getGTInfo(currentEU/20)))
    print(string.format("可用功率(时): %s EU/hour (%s)", ifformatScientific7(currentEU/3600/20), getGTInfo(currentEU/3600/20)))
    print(string.format("可用功率(天): %s EU/day (%s)", ifformatScientific7(currentEU/3600/20/24), getGTInfo(currentEU/3600/20/24)))
    
    print(string.format("每五秒均值:   %s EU/t (%s)", toColorString(fiveSecAvg), getGTInfo(fiveSecAvg)))
    print(string.format("每分钟均值:   %s EU/t (%s)", toColorString(minuteAvg), getGTInfo(minuteAvg)))
    print(string.format("五分钟均值:   %s EU/t (%s)", toColorString(fiveMinAvg), getGTInfo(fiveMinAvg)))
    print(string.format("每小时均值:   %s EU/t (%s)", toColorString(hourAvg), getGTInfo(hourAvg)))
    print(string.format("近一天均值:   %s EU/t (%s)", toColorString(dayAvg), getGTInfo(dayAvg)))
end

-- 开始主程序
-- 绘制部分

local x = 60 -- 分辨率
local y = 10 -- 分辨率
gpu.setViewport(x, y)

-- gpu.setBackground(0x44b6ff) -- 背景颜色，可自行修改
term.clear()
term.setCursorBlink(false)

function main() -- 主线程，负责显示部分
	-- 每秒运行一次
    while true do
        EU_Monitor.update()
        os.sleep(1)
    end
end
 
function checkTheard() -- 伴随线程，负责ctrl+c的中断处理
	event.pull("interrupted")
end
 
thread.waitForAny({thread.create(main), thread.create(checkTheard)})
