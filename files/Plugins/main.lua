require "import"
import "android.app.*"
import "android.os.*"
import "android.widget.*"
import "android.view.*"
import "android.content.*"
import "android.graphics.Typeface"
import "android.graphics.drawable.GradientDrawable"
import "android.speech.tts.TextToSpeech"
import "android.speech.tts.UtteranceProgressListener"
import "android.media.MediaPlayer"
import "android.net.Uri"
import "java.io.File"
import "java.util.Locale"
import "android.media.MediaScannerConnection"
import "java.io.RandomAccessFile"
import "java.io.FileInputStream"
import "java.io.FileOutputStream"

local service = service or activity

-- StrictMode Bypass for Sharing (Android 7.0+)
if Build.VERSION.SDK_INT >= 24 then
  pcall(function()
    local StrictMode = luajava.bindClass("android.os.StrictMode")
    local Builder = luajava.bindClass("android.os.StrictMode$VmPolicy$Builder")
    StrictMode.setVmPolicy(Builder().build())
  end)
end

-- Settings Saver Helpers
local prefs = service.getSharedPreferences("TTS_Maker_Config", 0)
local edit = prefs.edit()

function saveConfig(key, value)
  edit.putString(key, tostring(value))
  edit.apply()
end

function loadConfig(key)
  return prefs.getString(key, "")
end

-- Paths
local path = tostring(Environment.getExternalStorageDirectory()).."/TTS_Audio_Maker"
local dir = File(path)
if not dir.exists() then dir.mkdirs() end
local audioFile = File(path, "generated_voice.wav")

-- Global TTS Variables
local engineList = {}
local enginePackages = {}
local isGeneratingActive = false

-- Data structure to hold independent states for two speakers
local speakerData = {
  [1] = { tts = nil, voices = {}, langs = {}, filteredVoices = {} },
  [2] = { tts = nil, voices = {}, langs = {}, filteredVoices = {} }
}

-- Chunker Variables for Large Texts & Multiple Speakers
local synthesisQueue = {}
local tempFilesList = {}
local currentQueueIdx = 1

-- UI Layout
local layout = {
  ScrollView,
  layout_width="fill",
  layout_height="fill",
  backgroundColor="#FFFFFF",
  {
    LinearLayout,
    orientation="vertical",
    layout_width="fill",
    layout_height="wrap",
    padding="16dp",
    {
      TextView,
      id="title_lbl",
      text="Advanced Text to Speech Generator",
      textSize="20sp",
      layout_gravity="center",
      textColor="#212121",
      paddingBottom="10dp"
    },
    {
      CheckBox,
      id="two_speaker_check",
      text="Enable Two-Speaker Mode (Podcast Cast)",
      textSize="15sp",
      textColor="#E91E63",
      layout_marginBottom="10dp"
    },
    
    -- ================= SPEAKER 1 =================
    {
      LinearLayout,
      id="speaker1_container",
      orientation="vertical",
      layout_width="fill",
      {
        TextView,
        id="speaker1_title",
        text="Speaker 1 Settings",
        textSize="16sp",
        textColor="#2196F3",
        paddingBottom="5dp"
      },
      { TextView, text="1. Select Engine:", textSize="13sp", textColor="#757575" },
      { Spinner, id="engine_spinner_1", layout_width="fill", layout_height="45dp" },
      { TextView, text="2. Select Language:", textSize="13sp", textColor="#757575", layout_marginTop="5dp" },
      { Spinner, id="lang_spinner_1", layout_width="fill", layout_height="45dp" },
      { TextView, text="3. Select Voice:", textSize="13sp", textColor="#757575", layout_marginTop="5dp" },
      { Spinner, id="voice_spinner_1", layout_width="fill", layout_height="45dp" },
      { TextView, text="Pitch:", textSize="13sp", textColor="#757575", layout_marginTop="5dp" },
      { SeekBar, id="pitch_seek_1", max=200, progress=100, layout_width="fill" },
      { TextView, text="Speech Rate:", textSize="13sp", textColor="#757575", layout_marginTop="5dp" },
      { SeekBar, id="rate_seek_1", max=200, progress=100, layout_width="fill" },
      {
        Button,
        id="btn_test_voice_1",
        text="Test Speaker 1",
        layout_width="fill",
        layout_height="40dp",
        textSize="14sp",
        backgroundColor="#607D8B",
        textColor="#FFFFFF",
        layout_marginTop="5dp"
      },
      {
        EditText,
        id="input_text_1",
        layout_width="fill",
        layout_height="100dp",
        gravity="top",
        hint="Text for Speaker 1 (Press Enter for new line)...",
        layout_marginTop="10dp",
        padding="12dp",
        textColor="#000000",
        textSize="16sp"
      }
    },

    -- ================= SPEAKER 2 =================
    {
      LinearLayout,
      id="speaker2_container",
      orientation="vertical",
      layout_width="fill",
      visibility=8, -- GONE by default
      layout_marginTop="15dp",
      {
        TextView,
        id="speaker2_title",
        text="Speaker 2 Settings",
        textSize="16sp",
        textColor="#FF9800",
        paddingBottom="5dp"
      },
      { TextView, text="1. Select Engine:", textSize="13sp", textColor="#757575" },
      { Spinner, id="engine_spinner_2", layout_width="fill", layout_height="45dp" },
      { TextView, text="2. Select Language:", textSize="13sp", textColor="#757575", layout_marginTop="5dp" },
      { Spinner, id="lang_spinner_2", layout_width="fill", layout_height="45dp" },
      { TextView, text="3. Select Voice:", textSize="13sp", textColor="#757575", layout_marginTop="5dp" },
      { Spinner, id="voice_spinner_2", layout_width="fill", layout_height="45dp" },
      { TextView, text="Pitch:", textSize="13sp", textColor="#757575", layout_marginTop="5dp" },
      { SeekBar, id="pitch_seek_2", max=200, progress=100, layout_width="fill" },
      { TextView, text="Speech Rate:", textSize="13sp", textColor="#757575", layout_marginTop="5dp" },
      { SeekBar, id="rate_seek_2", max=200, progress=100, layout_width="fill" },
      {
        Button,
        id="btn_test_voice_2",
        text="Test Speaker 2",
        layout_width="fill",
        layout_height="40dp",
        textSize="14sp",
        backgroundColor="#607D8B",
        textColor="#FFFFFF",
        layout_marginTop="5dp"
      },
      {
        EditText,
        id="input_text_2",
        layout_width="fill",
        layout_height="100dp",
        gravity="top",
        hint="Text for Speaker 2 (Press Enter for new line)...",
        layout_marginTop="10dp",
        padding="12dp",
        textColor="#000000",
        textSize="16sp"
      }
    },

    -- ================= CONTROLS =================
    {
      Button,
      id="btn_convert",
      text="Generate Cast",
      layout_width="fill",
      layout_marginTop="15dp",
      backgroundColor="#4CAF50",
      textColor="#FFFFFF",
    },
    {
      LinearLayout,
      orientation="horizontal",
      layout_width="fill",
      layout_marginTop="10dp",
      {
        Button,
        id="btn_play",
        text="Play",
        layout_weight=1,
        backgroundColor="#2196F3",
        textColor="#FFFFFF",
        layout_marginRight="5dp"
      },
      {
        Button,
        id="btn_share",
        text="Share",
        layout_weight=1,
        backgroundColor="#9C27B0",
        textColor="#FFFFFF",
        layout_marginLeft="5dp"
      }
    },
    {
      TextView,
      id="status_lbl",
      text="Status: Initializing...",
      layout_marginTop="10dp",
      gravity="center",
      textColor="#E91E63",
    }
  }
}

local views = {}
local mainView = loadlayout(layout, views)

-- Safe Text Modification using correct Typeface bindings instead of textStyle string attributes
views.title_lbl.setTypeface(Typeface.DEFAULT_BOLD)
views.speaker1_title.setTypeface(Typeface.DEFAULT_BOLD)
views.speaker2_title.setTypeface(Typeface.DEFAULT_BOLD)

-- Styling Boxes
pcall(function()
  local gd = GradientDrawable()
  gd.setColor(0xFFFFFFFF)
  gd.setStroke(2, 0xFF4CAF50)
  gd.setCornerRadius(8)
  views.input_text_1.setBackground(gd)
  
  local gd2 = GradientDrawable()
  gd2.setColor(0xFFFFFFFF)
  gd2.setStroke(2, 0xFFFF9800)
  gd2.setCornerRadius(8)
  views.input_text_2.setBackground(gd2)
end)

local dlg = AlertDialog.Builder(service)
dlg.setView(mainView)
dlg.setNegativeButton("Minimize", nil)
local window = dlg.create()
window.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
window.show()

function showToast(msg)
  Toast.makeText(service, msg, Toast.LENGTH_SHORT).show()
end

-- Restore Persistent Input Fields Content
local savedText1 = loadConfig("saved_text_speaker_1")
if savedText1 ~= "" then views.input_text_1.setText(savedText1) end

local savedText2 = loadConfig("saved_text_speaker_2")
if savedText2 ~= "" then views.input_text_2.setText(savedText2) end

-- Text Input Change Monitors to instantly keep them saved
local TextWatcher = luajava.bindClass("android.text.TextWatcher")
views.input_text_1.addTextChangedListener(TextWatcher{
  afterTextChanged=function(editable)
    saveConfig("saved_text_speaker_1", editable.toString())
  end
})
views.input_text_2.addTextChangedListener(TextWatcher{
  afterTextChanged=function(editable)
    saveConfig("saved_text_speaker_2", editable.toString())
  end
})

-- Logic: Helper to extract lines from a text block
local function getLines(str)
  local t = {}
  for line in string.gmatch(str .. "\n", "(.-)\n") do
    line = string.gsub(line, "\r", "")
    table.insert(t, line)
  end
  if #t > 0 and t[#t] == "" then table.remove(t, #t) end
  return t
end

-- Logic: Text Splitter for Large Single-Line Articles
function splitTextByLimit(text, limit)
  local result = {}
  while string.len(text) > limit do
    local splitIdx = limit
    for i = limit, 1, -1 do
      local c = string.sub(text, i, i)
      if c == " " or c == "\n" or c == "." or c == "," or c == "!" or c == "?" then
        splitIdx = i
        break
      end
    end
    if splitIdx == limit and string.sub(text, splitIdx, splitIdx) ~= " " then
        splitIdx = limit 
    end
    table.insert(result, string.sub(text, 1, splitIdx))
    text = string.sub(text, splitIdx + 1)
  end
  if string.len(text) > 0 then
    table.insert(result, text)
  end
  return result
end

-- Logic: Merge Chunked WAV Files
function mergeWavFiles(outFile, inFiles)
  local out = FileOutputStream(outFile)
  local totalAudioLen = 0
  local buffer = byte[8192]
  
  for i, f in ipairs(inFiles) do
    local inStream = FileInputStream(f)
    if i > 1 then inStream.skip(44) end
    local bytesRead = inStream.read(buffer)
    while bytesRead ~= -1 do
      out.write(buffer, 0, bytesRead)
      bytesRead = inStream.read(buffer)
    end
    inStream.close()
    totalAudioLen = totalAudioLen + (f.length() - 44)
  end
  out.close()
  
  local raf = RandomAccessFile(outFile, "rw")
  local totalDataLen = totalAudioLen + 36
  
  local function writeIntLittleEndian(val)
    local b1 = math.floor(val % 256) val = math.floor(val / 256)
    local b2 = math.floor(val % 256) val = math.floor(val / 256)
    local b3 = math.floor(val % 256) val = math.floor(val / 256)
    local b4 = math.floor(val % 256)
    raf.write(b1) raf.write(b2) raf.write(b3) raf.write(b4)
  end
  
  raf.seek(4)
  writeIntLittleEndian(totalDataLen)
  raf.seek(40)
  writeIntLittleEndian(totalAudioLen)
  raf.close()
end

-- Logic: Execute Queue Synthesis
function generateQueueItem(idx)
  local item = synthesisQueue[idx]
  local tmpFile = tempFilesList[idx]
  item.tts.synthesizeToFile(item.text, Bundle(), tmpFile, "MAKER_Q_" .. idx)
end

-- Logic: Setup Listener
function setupTTSListener(speakerId)
  speakerData[speakerId].tts.setOnUtteranceProgressListener(UtteranceProgressListener{
    onStart = function(utteranceId) end,
    onDone = function(utteranceId)
      if string.sub(utteranceId, 1, 8) == "MAKER_Q_" then
        currentQueueIdx = currentQueueIdx + 1
        if currentQueueIdx <= #synthesisQueue then
          service.handler.post(Runnable{run=function()
            views.status_lbl.setText("Generating part " .. currentQueueIdx .. "/" .. #synthesisQueue .. "...")
          end})
          generateQueueItem(currentQueueIdx)
        else
          service.handler.post(Runnable{run=function()
            views.status_lbl.setText("Merging cast chunks...")
            
            task(100, function()
              pcall(function()
                mergeWavFiles(audioFile, tempFilesList)
                for _, f in ipairs(tempFilesList) do f.delete() end
              end)
              
              MediaScannerConnection.scanFile(service, {audioFile.getAbsolutePath()}, nil, nil)
              service.handler.post(Runnable{run=function()
                views.status_lbl.setText("Success! Audio Cast Saved.")
                views.btn_convert.setEnabled(true)
                isGeneratingActive = false
                window.show()
                showToast("Done")
              end})
            end)
          end})
        end
      end
    end,
    onError = function(utteranceId)
      service.handler.post(Runnable{run=function()
        views.status_lbl.setText("Error generating audio.")
        views.btn_convert.setEnabled(true)
        isGeneratingActive = false
        window.show()
      end})
    end
  })
end

-- Logic: Update Voices for a Specific Speaker
function updateVoiceList(speakerId, langIndex)
  local data = speakerData[speakerId]
  data.filteredVoices = {}
  local voiceNamesDisplay = {}
  
  if langIndex < 0 or not data.langs[langIndex+1] then return end

  local selectedLangName = data.langs[langIndex + 1]
  saveConfig("s" .. speakerId .. "_last_lang", selectedLangName)
  
  for _, voice in ipairs(data.voices) do
    local vLocale = voice.getLocale()
    if vLocale.getDisplayName() == selectedLangName then
      table.insert(data.filteredVoices, voice)
      local name = voice.getName()
      local variant = vLocale.getVariant()
      if variant and variant ~= "" then
        name = name .. " (" .. variant .. ")"
      end
      table.insert(voiceNamesDisplay, name)
    end
  end

  local vAdapter = ArrayAdapter(service, android.R.layout.simple_spinner_item, voiceNamesDisplay)
  vAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
  views["voice_spinner_" .. speakerId].setAdapter(vAdapter)

  local savedVoice = loadConfig("s" .. speakerId .. "_last_voice")
  if savedVoice ~= "" then
    for i, name in ipairs(voiceNamesDisplay) do
      if name == savedVoice then
        views["voice_spinner_" .. speakerId].setSelection(i-1)
        break
      end
    end
  end
end

-- Logic: Process Languages for a Specific Speaker
function processLanguages(speakerId)
  local data = speakerData[speakerId]
  data.langs = {}
  data.voices = {}
  local langSet = {} 
  
  local vIterator = data.tts.getVoices().iterator()
  while vIterator.hasNext() do
    local v = vIterator.next()
    if not v.isNetworkConnectionRequired() then
      table.insert(data.voices, v)
      local loc = v.getLocale()
      local langName = loc.getDisplayName()
      
      if not langSet[langName] then
        langSet[langName] = true
        table.insert(data.langs, langName)
      end
    end
  end
  
  table.sort(data.langs)

  service.handler.post(Runnable{run=function()
    local lAdapter = ArrayAdapter(service, android.R.layout.simple_spinner_item, data.langs)
    lAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
    views["lang_spinner_" .. speakerId].setAdapter(lAdapter)
    
    local savedLang = loadConfig("s" .. speakerId .. "_last_lang")
    local restored = false
    if savedLang ~= "" then
      for i, name in ipairs(data.langs) do
        if name == savedLang then
          views["lang_spinner_" .. speakerId].setSelection(i-1)
          restored = true
          break
        end
      end
    end
    
    if not restored and #data.langs > 0 then
      updateVoiceList(speakerId, 0)
    end
    
    if speakerId == 1 then views.status_lbl.setText("Ready") end
  end})
end

-- Logic: Init TTS for a Specific Speaker
function initTTS(speakerId, packageName)
  views.status_lbl.setText("Loading Engine for Speaker " .. speakerId .. "...")
  saveConfig("s" .. speakerId .. "_last_engine_pkg", packageName)

  if speakerData[speakerId].tts then
    speakerData[speakerId].tts.shutdown()
    speakerData[speakerId].tts = nil
  end
  
  speakerData[speakerId].tts = TextToSpeech(service, TextToSpeech.OnInitListener{
    onInit=function(status)
      if status == TextToSpeech.SUCCESS then
        processLanguages(speakerId)
        setupTTSListener(speakerId)
      else
        service.handler.post(Runnable{run=function()
          views.status_lbl.setText("Error: Speaker " .. speakerId .. " Init Failed")
        end})
      end
    end
  }, packageName)
end

-- Logic: Load Engines for Both Spinners
function loadEngines()
  local t = TextToSpeech(service, nil)
  task(200, function()
    engineList = {}
    enginePackages = {}
    local it = t.getEngines().iterator()
    while it.hasNext() do
      local info = it.next()
      table.insert(engineList, info.label)
      table.insert(enginePackages, info.name)
    end
    
    service.handler.post(Runnable{run=function()
      local eAdapter = ArrayAdapter(service, android.R.layout.simple_spinner_item, engineList)
      eAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
      
      views.engine_spinner_1.setAdapter(eAdapter)
      local savedPkg1 = loadConfig("s1_last_engine_pkg")
      local restored1 = false
      if savedPkg1 ~= "" then
        for i, pkg in ipairs(enginePackages) do
          if pkg == savedPkg1 then
            views.engine_spinner_1.setSelection(i-1)
            restored1 = true; break
          end
        end
      end
      if not restored1 and #enginePackages > 0 then views.engine_spinner_1.setSelection(0) end

      views.engine_spinner_2.setAdapter(eAdapter)
      local savedPkg2 = loadConfig("s2_last_engine_pkg")
      local restored2 = false
      if savedPkg2 ~= "" then
        for i, pkg in ipairs(enginePackages) do
          if pkg == savedPkg2 then
            views.engine_spinner_2.setSelection(i-1)
            restored2 = true; break
          end
        end
      end
      if not restored2 and #enginePackages > 0 then views.engine_spinner_2.setSelection(0) end

    end})
    t.shutdown()
  end)
end

-- Listeners for Speaker 1
views.engine_spinner_1.onItemSelected = function(p, v, pos, id)
  if pos >= 0 then initTTS(1, enginePackages[pos + 1]) end
end
views.lang_spinner_1.onItemSelected = function(p, v, pos, id) updateVoiceList(1, pos) end
views.voice_spinner_1.onItemSelected = function(p, v, pos, id)
  if pos >= 0 then saveConfig("s1_last_voice", tostring(views.voice_spinner_1.getItemAtPosition(pos))) end
end

-- Listeners for Speaker 2
views.engine_spinner_2.onItemSelected = function(p, v, pos, id)
  if pos >= 0 then initTTS(2, enginePackages[pos + 1]) end
end
views.lang_spinner_2.onItemSelected = function(p, v, pos, id) updateVoiceList(2, pos) end
views.voice_spinner_2.onItemSelected = function(p, v, pos, id)
  if pos >= 0 then saveConfig("s2_last_voice", tostring(views.voice_spinner_2.getItemAtPosition(pos))) end
end

-- Toggle Two-Speaker Mode & Persist Checkbox Toggle state
views.two_speaker_check.setOnCheckedChangeListener(CompoundButton.OnCheckedChangeListener{
  onCheckedChanged=function(buttonView, isChecked)
    if isChecked then
      views.speaker2_container.setVisibility(View.VISIBLE)
      saveConfig("dual_speaker_enabled", "true")
    else
      views.speaker2_container.setVisibility(View.GONE)
      saveConfig("dual_speaker_enabled", "false")
    end
  end
})

-- Restore dual-speaker visual configuration state
local dualState = loadConfig("dual_speaker_enabled")
if dualState == "true" then
  views.two_speaker_check.setChecked(true)
  views.speaker2_container.setVisibility(View.VISIBLE)
else
  views.two_speaker_check.setChecked(false)
  views.speaker2_container.setVisibility(View.GONE)
end

-- Shared Test Voice Function
local function testSpeakerVoice(speakerId)
  local vIndex = views["voice_spinner_" .. speakerId].getSelectedItemPosition()
  local tts = speakerData[speakerId].tts
  
  if vIndex >= 0 and tts then
    local selectedVoice = speakerData[speakerId].filteredVoices[vIndex + 1]
    tts.setVoice(selectedVoice)
    
    local pitchVal = views["pitch_seek_" .. speakerId].getProgress() / 100
    if pitchVal <= 0 then pitchVal = 0.1 end
    tts.setPitch(pitchVal)
    
    local rateVal = views["rate_seek_" .. speakerId].getProgress() / 100
    if rateVal <= 0 then rateVal = 0.1 end
    tts.setSpeechRate(rateVal)

    tts.speak("Testing speaker " .. speakerId, TextToSpeech.QUEUE_FLUSH, nil, "TEST_ID")
  else
    showToast("Select Voice First")
  end
end

views.btn_test_voice_1.onClick = function() testSpeakerVoice(1) end
views.btn_test_voice_2.onClick = function() testSpeakerVoice(2) end

-- Cast Generation Logic (Line by Line Interleaving)
views.btn_convert.onClick = function()
  local text1 = views.input_text_1.getText().toString()
  local text2 = views.input_text_2.getText().toString()
  local twoSpeaker = views.two_speaker_check.isChecked()

  if text1 == "" and (not twoSpeaker or text2 == "") then 
    showToast("Text is empty") 
    return 
  end
  
  if audioFile.exists() then audioFile.delete() end
  
  synthesisQueue = {}
  tempFilesList = {}
  currentQueueIdx = 1

  -- Extract line arrays
  local lines1 = getLines(text1)
  local lines2 = getLines(text2)
  local maxLines = math.max(#lines1, #lines2)

  local function queueSpeakerText(speakerId, text)
    -- Skip truly empty strings 
    if not string.match(text, "%S") then return end
    local vIndex = views["voice_spinner_" .. speakerId].getSelectedItemPosition()
    if vIndex < 0 then return end
    
    local tts = speakerData[speakerId].tts
    local selectedVoice = speakerData[speakerId].filteredVoices[vIndex + 1]

    tts.setVoice(selectedVoice)
    
    local pitchVal = views["pitch_seek_" .. speakerId].getProgress() / 100
    if pitchVal <= 0 then pitchVal = 0.1 end
    tts.setPitch(pitchVal)
    
    local rateVal = views["rate_seek_" .. speakerId].getProgress() / 100
    if rateVal <= 0 then rateVal = 0.1 end
    tts.setSpeechRate(rateVal)

    local chunks = splitTextByLimit(text, 3500)
    for i=1, #chunks do
      table.insert(synthesisQueue, {tts = tts, text = chunks[i], speaker = speakerId})
      table.insert(tempFilesList, File(path, "temp_q_" .. #synthesisQueue .. ".wav"))
    end
  end

  -- Loop through aligned lines sequentially
  for i = 1, maxLines do
    local l1 = lines1[i] or ""
    local l2 = lines2[i] or ""

    if string.match(l1, "%S") then
      queueSpeakerText(1, l1)
    end
    
    if twoSpeaker and string.match(l2, "%S") then
      queueSpeakerText(2, l2)
    end
  end

  if #synthesisQueue == 0 then 
    showToast("Select voices for the texts") 
    return 
  end

  views.btn_convert.setEnabled(false)
  views.status_lbl.setText("Generating part 1/" .. #synthesisQueue .. "...")
  
  -- Enable background generation flag and close dialog safely
  isGeneratingActive = true
  window.dismiss()
  
  generateQueueItem(1)
end

-- Global Media Player Instance
local globalPlayer = nil

views.btn_play.onClick = function()
  if not audioFile.exists() then 
    showToast("Generate audio first")
    return 
  end

  if globalPlayer == nil then
    pcall(function()
      globalPlayer = MediaPlayer()
      globalPlayer.setDataSource(audioFile.getAbsolutePath())
      globalPlayer.prepare()
      globalPlayer.start()
      views.btn_play.setText("Pause")
      
      globalPlayer.setOnCompletionListener(MediaPlayer.OnCompletionListener{
        onCompletion = function(mp)
          views.btn_play.setText("Play")
          globalPlayer.release()
          globalPlayer = nil
        end
      })
    end)
  else
    pcall(function()
      if globalPlayer.isPlaying() then
        globalPlayer.pause()
        views.btn_play.setText("Play")
      else
        globalPlayer.start()
        views.btn_play.setText("Pause")
      end
    end)
  end
end

views.btn_share.onClick = function()
  if not audioFile.exists() or audioFile.length() == 0 then
    showToast("No file to share")
    return 
  end
  
  window.dismiss()
  
  local intent = Intent(Intent.ACTION_SEND)
  intent.setType("audio/wav")
  intent.putExtra(Intent.EXTRA_STREAM, Uri.fromFile(audioFile))
  intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
  
  local chooser = Intent.createChooser(intent, "Share Audio Cast")
  chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
  
  service.startActivity(chooser)
end

-- Start initialization
loadEngines()

window.setOnDismissListener{onDismiss=function() 
  if not isGeneratingActive then
    if speakerData[1].tts then speakerData[1].tts.shutdown() end
    if speakerData[2].tts then speakerData[2].tts.shutdown() end
    if globalPlayer then globalPlayer.release() end
  end
end}

return true
