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

import Foundation
import SwiftDiscord
import SwiftRateLimiter
#if os(macOS)
import ImageBrutalizer

let machTaskBasicInfoCount = MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
#endif

typealias QueuedVideo = (link: String, channel: String)

class DiscordBot : DiscordClientDelegate {
    let client: DiscordClient
    let startTime = Date()

    fileprivate let weatherLimiter = RateLimiter(tokensPerInterval: 10, interval: "minute")
    fileprivate let wolframLimiter = RateLimiter(tokensPerInterval: 67, interval: "day")
    fileprivate var inVoiceChannel = false
    fileprivate var playingYoutube = false
    fileprivate var youtube = EncoderProcess()
    fileprivate var youtubeQueue = [QueuedVideo]()

    init(token: DiscordToken) {
        client = DiscordClient(token: token, configuration: [.log(.verbose), .shards(2), .fillUsers, .pruneUsers])
        client.delegate = self
    }

    func client(_ client: DiscordClient, didDisconnectWithReason reason: String) {
        print("bot disconnected")

        exit(0)
    }

    func client(_ client: DiscordClient, didCreateMessage message: DiscordMessage) {
        handleMessage(message)
    }

    func client(_ client: DiscordClient, isReadyToSendVoiceWithEngine engine: DiscordVoiceEngine) {
        print("voice engine ready")

        inVoiceChannel = true
        playingYoutube = false

        guard !youtubeQueue.isEmpty else { return }

        let video = youtubeQueue.remove(at: 0)

        client.sendMessage("Playing \(video.link)", to: video.channel)

        _ = playYoutube(channelId: video.channel, link: video.link)
    }

    func brutalizeImage(options: [String], channel: DiscordChannel) {
        #if os(macOS)
        let args = options.map(BrutalArg.init)
        var imagePath: String!

        loop: for arg in args {
            switch arg {
            case let .url(image):
                imagePath = image
                break loop
            default:
                continue
            }
        }

        guard imagePath != nil else {
            channel.sendMessage("Missing image url")

            return
        }

        guard let request = createGetRequest(for: imagePath) else {
            channel.sendMessage("Invalid url")

            return
        }

        getRequestData(for: request) {data in
            guard let data = data else {
                channel.sendMessage("Something went wrong with the request")

                return
            }

            guard let brutalizer = ImageBrutalizer(data: data) else {
                channel.sendMessage("Invalid image")

                return
            }

            for arg in args {
                arg.brutalize(with: brutalizer)
            }

            guard let outputData = brutalizer.outputData else {
                channel.sendMessage("Something went wrong brutalizing the image")

                return
            }

            channel.sendFile(DiscordFileUpload(data: outputData, filename: "brutalized.png", mimeType: "image/png"),
                content: "Brutalized:")
        }
        #else
        channel.sendMessage("Not available on Linux")
        #endif
    }

    func calculateStats() -> [String: Any] {
        var stats = [String: Any]()

        let guilds = client.guilds.map({ $0.value })
        let channels = client.guilds.flatMap({ $0.value.channels.map({ $0.value }) })
        let username = client.user!.username
        let guildNumber = guilds.count
        let numberOfTextChannels = channels.filter({ $0.type == .text }).count
        let numberOfVoiceChannels = channels.count - numberOfTextChannels
        let numberOfLoadedUsers = guilds.reduce(0, { $0 + $1.members.count })
        let totalUsers = guilds.reduce(0, { $0 + $1.memberCount })
        let shards = client.shards

        stats["name"] = username
        stats["numberOfGuilds"] = guildNumber
        stats["numberOfTextChannels"] = numberOfTextChannels
        stats["numberOfVoiceChannels"] = numberOfVoiceChannels
        stats["numberOfLoadedUsers"] = numberOfLoadedUsers
        stats["totalNumberOfUsers"] =  totalUsers
        stats["shards"] = shards
        stats["uptime"] = Date().timeIntervalSince(startTime)

        #if os(macOS)
        let name = mach_task_self_
        let flavor = task_flavor_t(MACH_TASK_BASIC_INFO)
        var size = mach_msg_type_number_t(machTaskBasicInfoCount)
        let infoPointer = UnsafeMutablePointer<mach_task_basic_info>.allocate(capacity: 1)

        task_info(name, flavor, unsafeBitCast(infoPointer, to: task_info_t!.self), &size)

        stats["memory"] = Double(infoPointer.pointee.resident_size) / 10e5

        infoPointer.deallocate(capacity: 1)
        #endif

        return stats
    }

    func connect() {
        client.connect()
    }

    func disconnect() {
        client.disconnect()
    }

    func findChannelFromName(_ name: String, in guild: DiscordGuild? = nil) -> DiscordGuildChannel? {
        // We have a guild to narrow the search
        if guild != nil, let channels = client.guilds[guild!.id]?.channels {
            return channels.filter({ $0.value.name == name }).map({ $0.1 }).first
        }

        // No guild, go through all the guilds
        // Returns first channel in the first guild with a match if multiple channels have the same name
        return client.guilds.flatMap({_, guild in
            return guild.channels.reduce(DiscordGuildChannel?.none, {cur, keyValue in
                guard cur == nil else { return cur } // already found

                return keyValue.value.name == name ? keyValue.value : nil
            })
        }).first
    }

    func getFortune() -> String {
        guard fortuneExists else {
            return "This bot doesn't have fortune installed"
        }

        let fortune = EncoderProcess()
        let pipe = Pipe()
        var saying: String!

        fortune.launchPath = "/usr/local/bin/fortune"
        fortune.standardOutput = pipe
        fortune.terminationHandler = {process in
            guard let fortune = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
                return
            }

            saying = fortune
        }

        fortune.launch()
        fortune.waitUntilExit()

        return saying
    }

    func getRolesForUser(_ user: DiscordUser, on channelId: String) -> [DiscordRole] {
        for (_, guild) in client.guilds where guild.channels[channelId] != nil {
            guard let userInGuild = guild.members[user.id] else {
                print("This user doesn't seem to be in the guild?")

                return []
            }

            return guild.roles.filter({ userInGuild.roles.contains($0.key) }).map({ $0.1 })
        }

        return []
    }

    private func handleMessage(_ message: DiscordMessage) {
        guard message.content.hasPrefix("$") else { return }

        let commandArgs = String(message.content.characters.dropFirst()).components(separatedBy: " ")
        let command = commandArgs[0]

        handleCommand(command.lowercased(), with: Array(commandArgs.dropFirst()), message: message)
    }

    func playYoutube(channelId: String, link: String) -> String {
        guard inVoiceChannel else { return "Not in voice channel" }
        guard !playingYoutube else {
            youtubeQueue.append((link, channelId))

            return "Video Queued. \(youtubeQueue.count) videos in queue"
        }

        playingYoutube = true

        youtube = EncoderProcess()
        youtube.launchPath = "/usr/local/bin/youtube-dl"
        youtube.arguments = ["-f", "bestaudio", "-q", "-o", "-", link]
        youtube.standardOutput = client.voiceEngine!.requestFileHandleForWriting()!

        youtube.terminationHandler = {[weak self] process in
            print("yt died")
            self?.client.voiceEngine?.encoder?.finishEncodingAndClose()
        }

        youtube.launch()

        return "Playing"
    }
}

extension DiscordBot : CommandHandler {
    func handleBrutal(with arguments: [String], message: DiscordMessage) {
        brutalizeImage(options: arguments, channel: message.channel!)
    }

    func handleCommand(_ command: String, with arguments: [String], message: DiscordMessage) {
        print("got command \(command)")

        if let guild = message.channel?.guild, ignoreGuilds.contains(guild.id),
                !userOverrides.contains(message.author.id) {
            print("Ignoring this guild")

            return
        }

        guard let command = Command(rawValue: command.lowercased()) else { return }

        switch command {
        case .roles:
            handleMyRoles(with: arguments, message: message)
        case .join where arguments.count > 0:
            handleJoin(with: arguments, message: message)
        case .leave:
            handleLeave(with: arguments, message: message)
        case .is:
            handleIs(with: arguments, message: message)
        case .youtube where arguments.count == 1:
            handleYoutube(with: arguments, message: message)
        case .fortune:
            handleFortune(with: arguments, message: message)
        case .skip:
            handleSkip(with: arguments, message: message)
        case .brutal where arguments.count > 0:
            handleBrutal(with: arguments, message: message)
        case .topic where arguments.count > 0:
            handleTopic(with: arguments, message: message)
        case .stats:
            handleStats(with: arguments, message: message)
        case .weather where arguments.count > 0:
            handleWeather(with: arguments, message: message)
        case .wolfram where arguments.count > 0:
            handleWolfram(with: arguments, message: message)
        case .forecast where arguments.count > 0:
            handleForecast(with: arguments, message: message)
        default:
            print("Bad command \(command)")
        }
    }

    func handleFortune(with arguments: [String], message: DiscordMessage) {
        message.channel?.sendMessage(getFortune())
    }

    func handleIs(with arguments: [String], message: DiscordMessage) {
        guard let guild = message.channel?.guild else {
            message.channel?.sendMessage("Is this a guild channel m8?")

            return
        }

        // Avoid evaluating every member.
        let members = guild.members.lazy.map({ $0.value })
        let randomNum = Int(arc4random_uniform(UInt32(guild.members.count - 1)))
        let randomIndex = members.index(members.startIndex, offsetBy: randomNum)
        let randomMember = members[randomIndex]
        let name = randomMember.nick ?? randomMember.user.username

        message.channel?.sendMessage("\(name) is \(arguments.joined(separator: " "))")
    }

    func handleJoin(with arguments: [String], message: DiscordMessage) {
        guard let channel = findChannelFromName(arguments.joined(separator: " "),
                in: client.guildForChannel(message.channelId)) else {
            message.channel?.sendMessage("That doesn't look like a channel in this guild.")

            return
        }

        guard channel.type == .voice else {
            message.channel?.sendMessage("That's not a voice channel.")

            return
        }

        client.joinVoiceChannel(channel.id)
    }

    func handleLeave(with arguments: [String], message: DiscordMessage) {
        client.leaveVoiceChannel()
    }

    func handleForecast(with arguments: [String], message: DiscordMessage) {
        let tomorrow = arguments.last == "tomorrow"
        let location: String

        if tomorrow {
            location = arguments.dropLast().joined(separator: " ")
        } else {
            location = arguments.joined(separator: " ")
        }

        weatherLimiter.removeTokens(1) {err, tokens in
            guard let forecast = getForecastData(forLocation: location),
                  let embed = createForecastEmbed(withForecastData: forecast, tomorrow: tomorrow) else {
                message.channel?.sendMessage("Something went wrong with getting the forecast data")

                return
            }

            message.channel?.sendMessage("", embed: embed)
        }
    }

    func handleMyRoles(with arguments: [String], message: DiscordMessage) {
        let roles = getRolesForUser(message.author, on: message.channelId)

        message.channel?.sendMessage("Your roles: \(roles.map({ $0.name }))")
    }

    func handleSkip(with arguments: [String], message: DiscordMessage) {
        if youtube.isRunning {
            youtube.terminate()
        }

        client.voiceEngine?.requestNewEncoder()
    }

    func handleStats(with arguments: [String], message: DiscordMessage) {
        message.channel?.sendMessage("", embed: createFormatMessage(withStats: calculateStats()))
    }

    func handleTopic(with arguments: [String], message: DiscordMessage) {
        message.channel?.modifyChannel(options: [.topic(arguments.joined(separator: " "))])
    }

    func handleWeather(with arguments: [String], message: DiscordMessage) {
        weatherLimiter.removeTokens(1) {err, tokens in
            guard let weatherData = getWeatherData(forLocation: arguments.joined(separator: " ")),
                  let embed = createWeatherEmbed(withWeatherData: weatherData) else {
                message.channel?.sendMessage("Something went wrong with getting the weather data")

                return
            }

            message.channel?.sendMessage("", embed: embed)
        }
    }

    func handleWolfram(with arguments: [String], message: DiscordMessage) {
        wolframLimiter.removeTokens(1) {err, tokens in
            message.channel?.sendMessage(getSimpleWolframAnswer(forQuestion: arguments.joined(separator: "+")))
        }
    }

    func handleYoutube(with arguments: [String], message: DiscordMessage) {
        message.channel?.sendMessage(playYoutube(channelId: message.channelId, link: arguments[0]))
    }
}
