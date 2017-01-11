// The MIT License (MIT)
// Copyright (c) 2016 Erik Little

// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without restriction, including without
// limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
// Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
// Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
// BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
// EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.

import CoreFoundation
import Dispatch
import Foundation
import struct SwiftDiscord.DiscordToken

let token = "Bot mysupersecrettoken" as DiscordToken
let weather = ""
let wolfram = ""
let authorImage = URL(string: "https://avatars1.githubusercontent.com/u/1211049?v=3&s=460")
let authorUrl = URL(string: "https://github.com/nuclearace")
let sourceUrl = URL(string: "https://github.com/nuclearace/SwiftDiscord")!
let ignoreGuilds = ["81384788765712384"]
let userOverrides = ["104753987663712256"]
let fortuneExists = FileManager.default.fileExists(atPath: "/usr/local/bin/fortune")

let queue = DispatchQueue(label: "Async Read")
let bot = DiscordBot(token: token)

func readAsync() {
    queue.async {
        guard let input = readLine(strippingNewline: true) else { return readAsync() }

        if input == "quit" {
            bot.disconnect()
        }

        readAsync()
    }
}

print("Type 'quit' to stop")

readAsync()

bot.connect()

CFRunLoopRun()
