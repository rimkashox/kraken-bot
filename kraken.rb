require 'pry-byebug'
require 'json'
require 'net/http'
require 'dotenv/load'
require 'kraken_client'

def timestamp
  Time.now.strftime('%m-%d %H:%M:%S')
end

def get_last_trade_price(client)
  ticker = client.public.ticker(ENV['TICKER_PAIR_NAME'])
  return nil if ticker.nil?

  ticker[ENV['TICKER_PAIR_NAME']]['c'][0].to_f
rescue Exception => e
  puts "#{timestamp} | API failure @ get_last_trade_price"
  nil
end

def market_buy(client)
  amount_in_btc = ENV['BUY_IN_AMOUNT'].to_f

  order = {
    pair: ENV['TRADE_PAIR_NAME'],
    type: 'buy',
    ordertype: 'market',
    volume: amount_in_btc
  }

  client.private.add_order(order)

  puts "#{timestamp} | --- BUYING #{amount_in_btc} #{ENV['COIN_COMMON_NAME']} ---"
rescue Exception => e
  puts "#{timestamp} | API failure @ market_buy"
  nil
end

def market_sell(client, amount_in_btc)
  order = {
    pair: ENV['TRADE_PAIR_NAME'],
    type: 'sell',
    ordertype: 'market',
    volume: amount_in_btc
  }

  client.private.add_order(order)

  puts "#{timestamp} | --- SELLING #{amount_in_btc} #{ENV['COIN_COMMON_NAME']} ---"
rescue Exception => e
  puts "#{timestamp} | API failure @ market_sell"
  nil
end

def get_current_coin_balance(client)
  balance = client.private.balance[ENV['BALANCE_COIN_NAME']]
  return nil if balance.nil?

  balance = balance.to_f.round(4)

  balance < ENV['MINIMUM_COIN_AMOUNT'].to_f ? 0.0 : balance
rescue Exception => e
  puts "#{timestamp} | API failure @ get_current_coin_balance"
  nil
end

def open_orders?(client)
  orders = client.private.open_orders
  return true if orders.nil?

  orders['open'].values.any? do |h|
    h.dig('descr', 'pair') == ENV['TRADE_PAIR_NAME'] && h.dig('descr', 'ordertype') == 'market'
  end
rescue Exception => e
  puts "#{timestamp} | API failure @ open_orders?"
  true
end

def get_last_closed_buy_trade(client, current_coins)
  return [] if current_coins.nil? || current_coins < ENV['MINIMUM_COIN_AMOUNT'].to_f

  orders = client.private.closed_orders
  return nil if orders.nil?

  orders = orders['closed'].values.select do |o|
    o['status'] == 'closed' && o.dig('descr', 'pair') == ENV['TRADE_PAIR_NAME'] &&
      o.dig('descr', 'type') == 'buy'
  end

  return [] unless orders.any?

  trade = orders.sort_by { |o| o['closetm'] }.last

  [OpenStruct.new(price: trade['price'].to_f, time: DateTime.strptime(trade['closetm'].to_i.to_s, '%s').to_time)]
rescue Exception => e
  puts "#{timestamp} | API failure @ get_last_closed_buy_trade"
  nil
end

def get_daily_high(client)
  ohlc = client.public.ohlc(pair: ENV['TICKER_PAIR_NAME'], interval: 1440)
  return nil if ohlc.nil?

  line = ohlc[ENV['TICKER_PAIR_NAME']]&.last
  return nil if line.nil? || line.count != 8

  line[2].to_f
rescue Exception => e
  puts "#{timestamp} | API failure @ get_daily_high"
  nil
end

def calculate_avg_buy_price(client, current_coins)
  return nil if current_coins.nil? || current_coins < ENV['MINIMUM_COIN_AMOUNT'].to_f

  orders = client.private.closed_orders
  return nil if orders.nil?

  orders = orders['closed'].values.select do |o|
    o['status'] == 'closed' && o.dig('descr', 'pair') == ENV['TRADE_PAIR_NAME'] &&
      o.dig('descr', 'type') == 'buy'
  end

  return nil unless orders.any?

  idx = 0
  total_btc = 0.0
  total_spent = 0.0
  while idx < orders.count
    spent = orders[idx]['cost'].to_f
    amount = orders[idx]['vol'].to_f

    break if total_btc + amount > current_coins

    total_spent += spent
    total_btc += amount

    break if total_btc == current_coins

    idx += 1
  end

  return nil if total_btc < ENV['MINIMUM_COIN_AMOUNT'].to_f

  total_spent / total_btc
rescue Exception => e
  puts "#{timestamp} | API failure @ calculate_avg_buy_price"
  nil
end

def buy(client, current_price, daily_high_price, current_coins)
  return false if current_price.nil? || daily_high_price.nil? || current_coins.nil?

  return false if current_coins >= ENV['MAX_COIN_TO_HOLD'].to_f

  return false if current_price > daily_high_price * (ENV['BUY_POINT'].to_f)

  last_buys = get_last_closed_buy_trade(client, current_coins)
  return false if last_buys.nil?

  if last_buys.any?
    last_buy = last_buys.first

    # Do not buy if the minimum wait after a period has not elapsed
    return false if Time.now - last_buy.time < ENV['BUY_WAIT_TIME'].to_i * 60 * 60

    # Do not buy if the price hasn't fallen since the last buy price
    return false if current_price > last_buy.price * (ENV['BUY_POINT'].to_f)
  end

  market_buy(client)
end

def sell(client, current_price, avg_buy_price, current_coins)
  return false if current_price.nil? || avg_buy_price.nil? || current_coins.nil?

  return false if current_coins < ENV['MINIMUM_COIN_AMOUNT'].to_f

  exit_value = avg_buy_price * (ENV['SELL_POINT'].to_f)

  return false if exit_value > current_price

  market_sell(client, current_coins)
end

STDOUT.sync = true

KrakenClient.configure do |config|
  config.api_key = ENV['KRAKEN_API_KEY']
  config.api_secret = ENV['KRAKEN_API_SECRET']
  config.base_uri = 'https://api.kraken.com'
  config.api_version = 0
  config.limiter = false
  config.tier = ENV['KRAKEN_USER_TIER'].to_i
end

client = KrakenClient.load

iteration = 0
daily_high_price_bak = nil
prev_str = nil

if %w[KRAKEN_API_KEY KRAKEN_API_SECRET KRAKEN_USER_TIER COIN_COMMON_NAME FIAT_COMMON_NAME TRADE_PAIR_NAME TICKER_PAIR_NAME BALANCE_COIN_NAME BUY_IN_AMOUNT BUY_POINT SELL_POINT MAX_COIN_TO_HOLD BUY_WAIT_TIME HOURS_DISABLED POLL_INTERVAL MINIMUM_COIN_AMOUNT].any? { |config| ENV[config].nil? }
  puts 'Incorrect config, check .env file'
  return
end

loop do
  if ENV['HOURS_DISABLED'].split(',').map(&:to_i).include?(Time.now.hour)
    puts "#{timestamp} | Outside business hours"
    sleep(5 * 60) # Sleep for 5 minutes
    next
  end

  sleep(ENV['POLL_INTERVAL'].to_i) if iteration != 0
  iteration += 1

  # Do not cache these values forever
  daily_high_price = nil if (iteration % 4) == 0

  next if open_orders?(client)

  current_coins = get_current_coin_balance(client)
  next if current_coins.nil?

  current_price = get_last_trade_price(client)
  next if current_price.nil?

  daily_high_price = get_daily_high(client)
  # Backup values of daily high prices
  if daily_high_price.nil?
    if daily_high_price_bak.nil?
      next
    else
      daily_high_price = daily_high_price_bak
      daily_high_price_bak = nil
    end
  else
    daily_high_price_bak = daily_high_price
  end

  avg_buy_price = calculate_avg_buy_price(client, current_coins)

  price_change = current_price.nil? || daily_high_price.nil? ? 1 : current_price / daily_high_price
  profit = current_price.nil? || avg_buy_price.nil? ? 0 : current_price / avg_buy_price - 1.0

  str = "Own: #{current_coins || 'n/a'} #{ENV['COIN_COMMON_NAME']}, avg buy price: #{avg_buy_price || 'n/a'} (#{(profit).round(1)}%), last market price: #{current_price || 'n/a'} #{ENV['FIAT_COMMON_NAME']} (#{(price_change).round(1)}%), daily high: #{daily_high_price || 'n/a'} #{ENV['FIAT_COMMON_NAME']}"

  if str != prev_str
    puts "#{timestamp} | #{str}"
    prev_str = str
  end

  next if buy(client, current_price, daily_high_price, current_coins)

  sell(client, current_price, avg_buy_price, current_coins)
end
