-- End-to-end tour of everything the panel does, over real Apple Events, against a signed-in StarPlayrX.
-- osascript StarPlayrXMac/Tests/ScriptedTour.applescript   → one "ok/FAIL step: detail" line per check.
on check(okay, label, detail)
	if okay then
		return "ok   " & label & ": " & detail & linefeed
	else
		return "FAIL " & label & ": " & detail & linefeed
	end if
end check

set out to ""
tell application id "com.starplayrx.mac"
	with timeout of 120 seconds
		if not signed in then return "FAIL not signed in"
		hide menu
		show menu
		set out to out & my check(menu visible and not menu detached, "show menu", "visible under the menu bar")

		-- Search field + click a row (select channel), then PDT shown vs. what actually plays.
		set allX to xtra channel numbers
		set x to item 1 of allX
		set search text to x
		set rows to visible channel numbers
		set out to out & my check(rows contains x, "search text", x & " → " & (count of rows) & " rows")
		set shown to now playing x
		set picked to select channel x
		repeat 120 times
			if playing song is not "" then exit repeat
			delay 0.5
		end repeat
		set played to playing artist & " – " & playing song
		set out to out & my check(picked and current channel is x, "select channel", x & " " & current channel name)
		set out to out & my check(shown is played, "PDT vs playing", "shown [" & shown & "] played [" & played & "]")
		set out to out & my check((shown artist & " – " & shown song) is played, "shown vs playing now", shown artist & " – " & shown song)

		-- Selecting a row the search hides does nothing.
		set search text to "zzzz no such channel"
		set out to out & my check((select channel x) is false and (count of visible channel numbers) is 0, "select hidden row", "refused")
		set search text to ""

		-- Play / pause button.
		toggle playback
		delay 1
		set out to out & my check(not playing, "pause", "playing " & playing)
		toggle playback
		delay 1
		set out to out & my check(playing, "play", "playing " & playing)

		-- Scrolling.
		set scrolled to scroll to channel "100"
		set out to out & my check(scrolled and top visible channel is "100", "scroll to channel", "top " & top visible channel & " at " & scroll position)
		set allChannels to channel numbers
		set scroll position to 0
		set out to out & my check(top visible channel is item 1 of allChannels, "scroll position 0", "top " & top visible channel)
		set scroll position to 600
		set out to out & my check(scroll position is 600, "scroll position 600", "top " & top visible channel)

		-- Drag: a short drag snaps back under the menu bar, a long one tears it off.
		set startPos to menu position
		set dragged to drag menu {10, 10}
		set q to menu position
		set out to out & my check(dragged is false and q is startPos, "short drag", "snapped back to " & (item 1 of q) & "," & (item 2 of q))
		set dragged to drag menu {-300, 200}
		set q to menu position
		set out to out & my check(dragged and menu detached, "tear off drag", "from " & (item 1 of startPos) & "," & (item 2 of startPos) & " to " & (item 1 of q) & "," & (item 2 of q))
		set menu position to {200, 150}
		set p to menu position
		set out to out & my check(item 1 of p is 200 and item 2 of p is 150, "move window", (item 1 of p) & "," & (item 2 of p))

		-- Window shade on / off.
		set fullSize to menu size
		set shadedNow to toggle shade
		delay 0.5
		set s to menu size
		set q to menu position
		set out to out & my check(shadedNow and item 2 of s < item 2 of fullSize and q is p, "shade on", "height " & (item 2 of fullSize) & " → " & (item 2 of s) & ", top-left stays " & (item 1 of q) & "," & (item 2 of q))
		set shadedNow to toggle shade
		delay 0.5
		set s to menu size
		set out to out & my check(not shadedNow and item 2 of s is item 2 of fullSize, "shade off", "height " & (item 2 of s))

		-- Park upper right, shaded.
		park menu at upper right shaded true
		delay 0.5
		set p to menu position
		set s to menu size
		set out to out & my check(menu detached and menu shaded, "park upper right shaded", "top-left " & (item 1 of p) & "," & (item 2 of p) & " size " & (item 1 of s) & "x" & (item 2 of s))
	end timeout
end tell
return out
