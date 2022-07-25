#!/usr/bin/env bash
TOKEN="TELEGRAM-BOT-TOKEN"
TG_GET_URL="https://api.telegram.org/bot$TOKEN/getUpdates"
TG_SEND_URL="https://api.telegram.org/bot$TOKEN/sendMessage"

HD="./db_exchange_rate"
[ -e $HD ] || mkdir -p ${HD}

tg_send(){
  curl -s -X POST $TG_SEND_URL -d chat_id=$2 -d text="$1" -d parse_mode="HTML" > /dev/null 2>&1
}
log(){
  echo "$(date): ${1}" | tee -a tzex.log
}

tg_bot() {
  local tlu_file="./tg_last_update_test"
  [ -e $tlu_file ] && TG_UPDATE_ID="$(<${tlu_file})"
  [ -z "$TG_UPDATE_ID" ] && TG_UPDATE_ID=0
  while true
  do
    local update_id=""
    local tg_user_id=""
    local mess=""
      while read -r update_id tg_user_id mess
      do
        [ -z "${tg_user_id}" ] && continue
        [ -z "${mess}" ] && continue
        [ -z "${update_id}" ] && continue
        [ "${update_id}" -le "${TG_UPDATE_ID}" ] && continue
        local dir="${HD}/${tg_user_id}"
        [ ! -d $dir ] && continue

        TG_UPDATE_ID="${update_id}"

        mess=$(eval "echo $mess")

        log "[Info] $update_id:$TG_UPDATE_ID > $tg_user_id: $mess"

        [ "${mess}" == "/list" ] && {
          local list="$(find ${dir}/ -type d -depth 1 -maxdepth 1 -execdir printf "%s\n" {} \;)"
          local send_list=""
          for token in ${list}
          do
            send_list="$(printf "%s\n%s: [ %f <b>%f</b> %f ]\n" "$send_list" "$token" "$(cat ${dir}/${token}/ut)" "$(cat ${dir}/${token}/rate)" "$(cat ${dir}/${token}/lt)")"
          done
          tg_send "$send_list" "${tg_user_id}"
          continue
        }

        local add=$(expr "$mess" : "^/add \([a-zA-Z0-9_-]\{1,18\} KT[a-zA-Z0-9_]\{34,40\} KT[a-zA-Z0-9_]\{34,40\} [0-9]\{1,18\}[,.]\{0,1\}[0-9]\{0,9\}\)$")
        [ ! -z "$add" ] && {
          echo "$add" | while read -r token addr1 addr2 coef
          do
            local tdir="${dir}/${token}"
            mkdir -p ${tdir}
            printf "%s" "${addr1}" > ${tdir}/addr1
            printf "%s" "${addr2}" > ${tdir}/addr2
            coef=$(echo "$coef" | tr ',' '.')
            printf "%f" "${coef}" > ${tdir}/coef

            jquery="([ .[].level ] | max) as \$m| map(select(.level== \$m))|.[0].value.storage | [(.tez_pool | tonumber)/(.token_pool|tonumber)*${coef}] | @sh"
            rate="$(curl -s https://api.tzkt.io/v1/contracts/${addr2}/storage/history | jq -rec "${jquery}")"

            tg_send "$token was created with coefficient $coef! Now you need set upper and lower tresholds via /ut and /lt commands %0A<b>Current rate = ${rate}</b>" "$tg_user_id"
          done
          continue
        }

        local ut=$(expr "$mess" : "^/ut \([a-zA-Z0-9_-]\{1,18\} [0-9]\{1,18\}[,.]\{0,1\}[0-9]\{0,18\}\)$")
        [ ! -z "${ut}" ] && {
          echo "${ut}" | while read -r token upper_threshold
          do
            local tdir="${dir}/${token}"
            [ ! -e ${tdir} ] && {
              tg_send "Error: token '${token}' not exist" "$tg_user_id"
              continue
            }
            upper_threshold=$(echo "$upper_threshold" | tr ',' '.')
            printf "%f" "${upper_threshold}" > ${tdir}/ut
            tg_send "$token upper treshold now set to $upper_threshold" "$tg_user_id"
            local f_alerted="${tdir}/alerted"
            [ -e ${f_alerted} ] && rm -f ${f_alerted}
          done
          continue
        }


        local lt=$(expr "$mess" : "^/lt \([a-zA-Z0-9_-]\{1,18\} [0-9]\{1,18\}[,.]\{0,1\}[0-9]\{0,18\}\)$")
        [ ! -z "${lt}" ] && {
          echo "${lt}" | while read -r token lower_threshold
          do
            local tdir="${dir}/${token}"
            [ ! -e ${tdir} ] && {
              tg_send "Error: token '${token}' not exist" "$tg_user_id"
              continue
            }
            lower_threshold=$(echo "$lower_threshold" | tr ',' '.')
            printf "%f" "${lower_threshold}" > ${tdir}/lt
            tg_send "$token lower treshold now set to $lower_threshold" "$tg_user_id"
            local f_alerted="${tdir}/alerted"
            [ -e ${f_alerted} ] && rm -f ${f_alerted}
          done
          continue
        }

        local del=$(expr "$mess" : "^/del \([a-zA-Z0-9_-]\{1,18\}\)$")
        [ ! -z "${del}" -a -e "${dir}/${del}" ] && {
          rm -rf ${dir}/${del} && tg_send "$del was deleted" "$tg_user_id"
          continue
        }

        local solo=$(expr "$mess" : "^/solo \([a-zA-Z0-9_-]\{1,18\}\)$")
        [ ! -z "${solo}" ] && {
          echo "$solo" > "${dir}/solo@"
          tg_send "Solo mode activated foor $solo token" "$tg_user_id"
          continue
        }

        [ "$mess" == "/all" ] && {
          rm -f "${dir}/solo@"
          tg_send "Solo mode deactivated" "$tg_user_id"
          continue
        }


        [ "${mess}" != "/start" ] && tg_send "Error in command: '$mess'" "$tg_user_id"

      done <<< $(curl -s -X POST $TG_GET_URL -d offset=${TG_UPDATE_ID} |
        jq -reM ".result[] | select(.update_id > ${TG_UPDATE_ID} and .message.entities[0].type != null) | select(.message.text) | [.update_id, .message.chat.id, .message.text] | @sh")
    printf "%d" "${TG_UPDATE_ID}" > ${tlu_file}
    sleep 2
  done
}

tg_bot &
tg_pid=$!

quit(){
  log "Good bye! Exiting.."
  #local myjobs="`jobs -p`"
  #kill -SIGPIPE $myjobs >/dev/null 2>&1
  kill -9 $tg_pid > /dev/null 2>&1
  exit 0
}

trap quit SIGHUP SIGINT SIGTERM

while true
do
  for chat_id in $(ls -1 ${HD})
  do
    DIR="${HD}/${chat_id}"
    for token in $(ls -1 ${DIR})
    do
      [ "$token" == "solo@" ] && continue
      [ -e "${DIR}/solo@" ] && [ "$(cat ${DIR}/solo@)" != "$token" ] && continue
      dir=${DIR}/${token}
      f_addr1=${dir}/addr1
      f_addr2=${dir}/addr2
      f_coef=${dir}/coef
      f_ut=${dir}/ut
      f_lt=${dir}/lt

      [ ! -e ${f_addr1} -o ! -e ${f_addr1} -o ! -e ${f_coef} -o ! -e ${f_ut} -o ! -e ${f_lt} ] && continue

      addr1=$(<${f_addr1})
      addr2=$(<${f_addr2})
      [ -z "${addr1}" -o -z "${addr2}" ] && continue
      coefficient=$(<${f_coef})
      [ -z "${coefficient}" ] && continue
      upper_threshold=$(<${f_ut})
      lower_threshold=$(<${f_lt})
      [ -z "${upper_threshold}" -o -z ${lower_threshold} ] && continue
      jquery="([ .[].level ] | max) as \$m| map(select(.level== \$m))|.[0].value.storage | [(.tez_pool | tonumber)/(.token_pool|tonumber)*${coefficient}] | @sh"
      hist="$(curl -s https://api.tzkt.io/v1/contracts/${addr2}/storage/history)"
      rate="$(echo "$hist" | jq -rec "${jquery}")"

      [ -z "$upper_threshold" -o -z "$lower_threshold" -o -z "$rate" ] && {
        log "[ERROR] upper_threshold: '$upper_threshold' lower_threshold: '$lower_threshold' rate: '$rate' json: '$hist' ($dir)"
        continue
      }

      printf "${rate}" > ${dir}/rate
      link1="https://quipuswap.com/swap?from=${addr1}%26to=tez"
      link1="<a href=\"${link1}\">quipuswap</a>"
      #link2="https://pezos-sandbox.duckdns.org/?address=${addr1}"
      link2="https://pezos.fi/?identifier=${addr1}"
      link2="<a href=\"${link2}\">pezos</a>"
      link3="https://tzkt.io/${addr2}/operations/"
      link3="<a href=\"${link3}\">tzkt</a>"

      f_alerted=${dir}/alerted
      [ "$(echo $rate'>'$upper_threshold | bc -l)" == "1" ] && {
        [ -e ${f_alerted} ] && [ "${rate}" == "$(<$f_alerted)" ] && continue
        log "[ALERT] $rate > $upper_threshold ($dir)"
        alert_message=$(printf 'The current %s rate <b>%f</b> has <b>exceeded</b> the specified range:' "$token" "$rate")
        alert_message=$(printf '%s\n Upper threshold is %f\n Lower threshold is %f' "$alert_message" "$upper_threshold" "$lower_threshold")
        tg_send "${alert_message}%0A${link1}%0A${link2}%0A${link3}" "${chat_id}"
        printf "${rate}" > ${f_alerted}
      }

      [ "$(echo $rate'<'$lower_threshold | bc -l)" == "1" ] && {
        [ -e ${f_alerted} ] && [ "${rate}" == "$(<$f_alerted)" ] && continue
        log "[ALERT] $rate < $upper_threshold ($dir)"
        alert_message=$(printf 'The current %s rate <b>%f</b> has <b>dropped below</b> the specified range:' "$token" "$rate")
        alert_message=$(printf '%s\n Upper threshold is %f\n Lower threshold is %f' "$alert_message" "$upper_threshold" "$lower_threshold")
        tg_send "${alert_message}%0A${link1}%0A${link2}%0A${link3}" "${chat_id}"
        printf "${rate}" > ${f_alerted}
      }
    done
  done
  sleep 2
done
