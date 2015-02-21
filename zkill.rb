require 'yaml'
require 'json'
require 'rest_client'
require 'rufus/scheduler'
require 'csv'
require 'logger'
require 'action_view'

$approot = File.expand_path(File.dirname(__FILE__))
@config = YAML.load_file("#{$approot}/config.yml")
@systems = Hash[*CSV.read("#{$approot}/systems.csv").flatten]
@ships = Hash[*CSV.read("#{$approot}/ships.csv").flatten]
@logger = Logger.new('logfile.log')

def process_kills
  k = Kills.new(@config)
  @logger.info("Checking Kills #{k}")
  if k.count > 0 then
    k.kills.each do |kill|
      RestClient.post @config["webhook_url"], payload(kill).to_json
    end
    update_last_kill(k.last_kill_id)
  end
end

def payload(kill)
  # kill or loss
  type = "Kill"
  color = "good"

  if kill["victim"][@config["modifier"]] == @config["modifier_id"] then
    type =  "Loss"
    color = "danger"
  end

  #https://www.fuzzwork.co.uk/dump/latest/
  #invUniquenames.csv - systems - only need group 5
  #invTypes.csv - ships
  system_name = @systems[kill["solarSystemID"].to_s]
  ship_killed = @ships[kill["victim"]["shipTypeID"].to_s]

  victim_name = kill["victim"]["characterName"]
  victim_id = kill["victim"]["characterID"]
  victim_corp_id = kill["victim"]["corporationID"]
  victim_alliance_id = kill["victim"]["allianceID"]
  victim_corp_name = kill["victim"]["corporationName"]
  victim_alliance_name = kill["victim"]["allianceName"]

  killer = kill["attackers"].find { |a| a["finalBlow"].to_s == "1" } || {}

  @logger.debug("final blow: #{killer["characterName"]}")
  @logger.debug(kill)

  final_blow_name =  killer["characterName"]
  final_blow_id = killer["characterID"]
  final_blow_corp_id = killer["corporationID"]
  final_blow_corp_name = killer["corporationName"]
  final_blow_alliance_id = killer["allianceID"]
  final_blow_alliance_name = killer["allianceName"]

  victim_value = "<https://zkillboard.com/character/#{victim_id}/|#{victim_name}>"
  final_blow_value = "<https://zkillboard.com/character/#{final_blow_id}/|#{final_blow_name}>"
  victim_corp_value = "<https://zkillboard.com/corporation/#{victim_corp_id}/|#{victim_corp_name}>"
  final_blow_corp_value = "<https://zkillboard.com/corporation/#{final_blow_corp_id}/|#{final_blow_corp_name}>"

  victim_alliance_value = victim_alliance_id.to_s != "0" ? "<https://zkillboard.com/alliance/#{victim_alliance_id}/|#{victim_alliance_name}>" : "none"
  final_blow_alliance_value = final_blow_alliance_id.to_s != "0" ? "<https://zkillboard.com/alliance/#{final_blow_alliance_id}/|#{final_blow_alliance_name}>" : "none"


  kill_time = kill["killTime"]
  isk_value = ActionView::Base.new.number_to_human(kill["zkb"]["totalValue"].to_i)

  text = "<https://zkillboard.com/kill/#{kill["killID"]}|View #{type}>"
  icon_url = "https://image.eveonline.com/Type/#{kill["victim"]["shipTypeID"]}_64.png"
  fallback = "#{type} - #{final_blow_name} killed #{victim_name} in a #{ship_killed}"

  pl = {
  "username": "zKillboard",
  "text": text,
  "icon_url": icon_url,
  "attachments": [
    {
      "fallback": fallback,
      "fields": [
        {
          "title": "Victim",
          "value": victim_value,
          "short": true
        },
        {
          "title": "Final Blow",
          "value": final_blow_value,
          "short": true
        },
        {
          "title": "Corp",
          "value": victim_corp_value,
          "short": true
        },
        {
          "title": "Corp",
          "value": final_blow_corp_value,
          "short": true
        },
        {
          "title": "Alliance",
          "value": victim_alliance_value,
          "short": true
        },
        {
          "title": "Alliance",
          "value": final_blow_alliance_value,
          "short": true
        },
        {
          "title": "Time",
          "value": kill_time,
          "short": true
        },
        {
          "title": "Ship",
          "value": ship_killed,
          "short": true
        },
        {
          "title": "Place",
          "value": system_name,
          "short": true
        },
        {
          "title": "Value",
          "value": isk_value,
          "short": true
        }
      ],
      "color": color
    }
  ]
  }
  return pl
end


def update_last_kill(id)
  @config["last_kill"] = id.to_s
  File.open("#{$approot}/config.yml", 'w') { |f| YAML.dump(@config, f) }
end

class Kills
  def initialize(config)
    @webhook_url = config["webhook_url"]
    @modifier = config["modifier"]
    @modifier_id = config["modifier_id"]
    @last_kill = config["last_kill"]
    fetch_kills
  end

  def url
    "https://zkillboard.com/api/#{@modifier}/#{@modifier_id}/no-items/orderDirection/asc/afterKillID/#{@last_kill}/"
  end

  def fetch_kills
    @kills = JSON.parse(get)
  end

  def get
    @response = RestClient.get url, { "Accept-Encoding": "gzip", "User-Agent": "Slack notification" }
    return @response
  rescue RestClient::NotModified
    puts "304 returned"
    return "{}"
  end

  def kills
    @kills.sort_by { |a| a["killID"].to_i }
  end

  def count
    @kills.count || 0
  end

  def last_kill_id
    kills.last["killID"] || nil
  end
end


SCHEDULER = Rufus::Scheduler.new

SCHEDULER.every '5m', :first => :now do
  process_kills
end

SCHEDULER.join
