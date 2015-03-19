#********************************************************************************************************
#* CREATION OF MOH 731 INDICATORS TABLE ****************************************************************************
#********************************************************************************************************

# Need to first create this temporary table to sort the data by person,encounterdateime. 
# This allows us to use the previous row's data when making calculations.
# It seems that if you don't create the temporary table first, the sort is applied 
# to the final result. Any references to the previous row will not an ordered row. 


drop table if exists flat_moh_731_indicators_0;
create temporary table flat_moh_731_indicators_0(index encounter_id (encounter_id), index person_enc (person_id,encounter_datetime))
(select * from 
	((select t0.person_id, e.encounter_id, e.encounter_datetime, e.encounter_type
		from amrs.encounter e
			join flat_new_person_data t0 on e.patient_id = t0.person_id
		where encounter_type in (1,2,3,4,10,13,14,15,17,19,22,23,26,43,47,21)
			and voided=0
		order by t0.person_id, e.encounter_datetime
		limit 100000
	)

	union

	(select t0.person_id, t0.encounter_id, t0.obs_datetime as encounter_datetime, 99999 as encounter_type
		from flat_ext_data t0
			join flat_new_person_data t1 using(person_id)
		limit 100000
	)) t1
	order by person_id, encounter_datetime
);

select @prev_id := null;
select @cur_id := null;
select @cur_rtc_date := null;
select @prev_rtc_date := null;
select @hiv_start_date := null;
select @arv_start_date := null;
select @arv_first_regimen := null;
select @cur_arv_line := null;
select @first_evidence_pt_pregnant := null;
select @edd := null;
select @cur_arv_meds := null;
select @tb_treatment_start_date := null;
select @pcp_prophylaxis_start_date := null;
select @screened_for_tb := null;
select @death_date := null;

#TO DO
# enrolled in care
# screened for cervical ca
# provided with condoms
# modern contraceptive methods
# transfer_status
# dead
# exposed infant

drop temporary table if exists flat_moh_731_indicators_1;
create temporary table flat_moh_731_indicators_1 (index encounter_id (encounter_id))
(select 
	@prev_id := @cur_id as prev_id, 
	@cur_id := t1.person_id as cur_id,
	t1.person_id,
	t1.encounter_id,
	t1.encounter_datetime,			
	scheduled_visit,
	case
        when @prev_id=@cur_id then @prev_rtc_date := @cur_rtc_date
        else @prev_rtc_date := null
	end as prev_rtc_date,
	@cur_rtc_date := rtc_date as cur_rtc_date,

	#not working
	case
		when discontinue_is_hiv_neg=1065 then @hiv_start_date := null
		when ext_hiv_rapid_test=664 or ext_hiv_dna_pcr=664 then @hiv_start_date:=null
		when @prev_id != @cur_id or @hiv_start_date is null then
			case
				when ext_hiv_rapid_test=703 or ext_hiv_dna_pcr=703 then @hiv_start_date := encounter_datetime
				when arvs_current or arv_plan then @hiv_start_date := encounter_datetime
				else @hiv_start_date := null 
			end
		else @hiv_start_date
	end as hiv_start_date,


	case
		when arv_plan = 1256 then @arv_start_date := t1.encounter_datetime
		when arv_plan in (1107,1260) then @arv_start_date := null
		when @prev_id = @cur_id and arv_started is not null and @arv_start_date is null then @arv_start_date := t1.encounter_datetime
		when @prev_id = @cur_id and arvs_current is not null and @arv_start_date is null then @arv_start_date := t1.encounter_datetime
		when @prev_id != @cur_id then @arv_start_date := null
		else @arv_start_date
	end as arv_start_date,


	case
		when arv_plan in (1107,1260) then @cur_arv_meds := null
		when arv_started then @cur_arv_meds := arv_started
		when arvs_current then @cur_arv_meds := arvs_current
		when @prev_id=@cur_id then @cur_arv_meds
		else @cur_arv_meds:= null
	end as cur_arv_meds,

	case
		when @arv_first_regimen is null and @cur_arv_meds is not null then @arv_first_regimen := @cur_arv_meds
		when @prev_id = @cur_id then @arv_first_regimen
		else @arv_first_regimen := null
	end as arv_first_regimen,

	case
		when arv_plan in (1107,1260) then @cur_arv_line := null
		when arv_started regexp '[[:<:]]6467|6964|792|633|631[[:>:]]' then @cur_arv_line := 1
		when arv_started regexp '[[:<:]]794[[:>:]]' then @cur_arv_line := 2
		when arv_started regexp '[[:<:]]6156[[:>:]]' then @cur_arv_line := 3
		when arvs_current regexp '[[:<:]]6467|6964|792|633|631[[:>:]]' then @cur_arv_line := 1
		when arvs_current regexp '[[:<:]]794[[:>:]]' then @cur_arv_line := 2
		when arvs_current regexp '[[:<:]]6156[[:>:]]' then @cur_arv_line := 3
		when @prev_id = @cur_id then @cur_arv_line
		else @cur_arv_line := null
	end as cur_arv_line,

	case
		when @prev_id != @cur_id then
			case
				when t1.encounter_type in (32,33,44,10) /*or is_pregnant=1065*/ or num_weeks_preg or expected_delivery_date then @first_evidence_pt_pregnant := encounter_datetime
				else @first_evidence_pt_pregnant := null
			end
		when @first_evidence_pt_pregnant is null and (t1.encounter_type in (32,33,44,10) /*or is_pregnant=1065*/ or num_weeks_preg or expected_delivery_date) then @first_evidence_pt_pregnant := encounter_datetime
		when @first_evidence_pt_pregnant and (t1.encounter_type in (11,47,34) or timestampdiff(week,@first_evidence_pt_pregnant,encounter_datetime) > 40 or timestampdiff(week,@edd,encounter_datetime) > 4 or actual_delivery_date or delivered_since_last_visit=1065) then @first_evidence_pt_pregnant := null
		else @first_evidence_pt_pregnant
	end as first_evidence_patient_pregnant,
	
	case
		when @prev_id != @cur_id then
			case
				when @first_evidence_patient_pregnant and lmp then @edd := date_add(lmp,interval 280 day)
				when num_weeks_preg then @edd := date_add(encounter_datetime,interval (40-num_weeks_preg) week)
				when expected_delivery_date then @edd := expected_delivery_date
				when @first_evidence_pt_pregnant then @edd := date_add(@first_evidence_pt_pregnant,interval 6 month)
				else @edd := null
			end
		when @edd is null or @edd = @first_evidence_pt_pregnant then
			case
				when @first_evidence_pt_pregnant and lmp then @edd := date_add(lmp,interval 280 day)
				when num_weeks_preg then @edd := date_add(encounter_datetime,interval (40-num_weeks_preg) week)
				when expected_delivery_date then @edd := expected_delivery_date
				when @first_evidence_pt_pregnant then @edd := date_add(@first_evidence_pt_pregnant,interval 6 month)
				else @edd
			end
		when @edd and (t1.encounter_type in (11,47,34) or timestampdiff(week,@edd,encounter_datetime) > 4 or actual_delivery_date or delivered_since_last_visit=1065) then @edd := null
		else @edd	
	end as edd,		

	case 
		when tb_symptom is not null then @screened_for_tb := true #there is an obs for "any symptoms of tb?"
		when tb_dx_this_visit = 1065 then @screened_for_tb := true #1065 = yes
		when tb_tx_plan in (1256,1850) then @screened_for_tb := true #1256=start, 1850=restart
		when tb_tx_started and tb_tx_plan != 1257 then @screened_for_tb := true #1257=continue
	end as screened_for_tb,

	case 
		when tb_tx_plan in (1256) then @tb_treatment_start_date := encounter_datetime
		when tb_tx_plan in (1257,1259,1849,981) then
			case
				when @prev_id!=@cur_id or @tb_treatment_start_date is null then @tb_treatment_start_date := encounter_datetime
				else @tb_treatment_start_date
			end
		when (tb_tx_current_plan !=1267 or tb_tx_plan !=1267) and @tb_treatment_start_date is null then @tb_treatment_start_date := encounter_datetime
		when @prev_id=@cur_id then @tb_treatment_start_date
		else @tb_treatment_start_date := null
	end as tb_tx_start_date,

	case 
		when pcp_prophy_plan in (1256,1850) then @pcp_prophylaxis_start_date := encounter_datetime
		when pcp_prophy_plan=1257 then
			case
				when @prev_id!=@cur_id or @pcp_prophylaxis_start_date is null then @pcp_prophylaxis_start_date := encounter_datetime
				else @pcp_prophylaxis_start_date
			end
		when pcp_prophy_current in (916,92) and @pcp_prophylaxis_start_date is null then @pcp_prophylaxis_start_date := encounter_datetime
		when current_meds regexp '[[:<:]]916[[:>:]]' and @pcp_prophylaxis_start_date is null then @pcp_prophylaxis_start_date := encounter_datetime
		when @prev_id=@cur_id then @pcp_prophylaxis_start_date
		else @pcp_prophylaxis_start_date := null
	end as pcp_prophylaxis_start_date,

	case
		when p.dead or p.death_date then @death_date := p.death_date
		when t8.death_date then @death_date := t8.death_date
		when @prev_id != @cur_id or @death_date is null then 
			case
				when t8.death_reported_by or t8.death_cause then @death_date := encounter_datetime
				when reason_for_missed_visit = 159 or patient_care_status=159 or encounter_type=31 or tb_tx_outcome=159 then @death_date := encounter_datetime
				else @death_date := null
			end
		else @death_date
	end as death_date
	
from flat_moh_731_indicators_0 t1
	left outer join flat_arvs t2 using (encounter_id, person_id)
	left outer join flat_drug t3 using (encounter_id, person_id)
	left outer join flat_maternity t4 using (encounter_id, person_id)
	left outer join flat_tb t6 using (encounter_id, person_id)
	left outer join flat_encounter t7 using (encounter_id,person_id)
	left outer join flat_handp t8 using (encounter_id,person_id)
	left outer join flat_int_data t9 using (encounter_id,person_id)
	left outer join flat_ext_data t10 using (encounter_id,person_id)
	left outer join amrs.person p using (person_id)
);



drop table if exists flat_moh_731_indicators;
create table if not exists flat_moh_731_indicators (
	person_id int,
    encounter_id int,
	encounter_datetime datetime,
	death_date datetime,
	scheduled_visit int,
	prev_rtc_date datetime,
	rtc_date datetime,
	arv_start_date datetime,
	arv_first_regimen varchar(500),
	cur_arv_meds varchar(500),
	cur_arv_line int,
    first_evidence_patient_pregnant datetime,
    edd datetime,
	screened_for_tb boolean,
	tb_tx_start_date datetime,
	pcp_prophylaxis_start_date datetime,	
    primary key encounter_id (encounter_id),
    index person_id (person_id)
);

delete t1
from flat_moh_731_indicators t1
join flat_new_person_data t2 using (person_id);

insert into flat_moh_731_indicators
(select 
	person_id,
    encounter_id,
	encounter_datetime,
	death_date,
	scheduled_visit,
	prev_rtc_date,
	cur_rtc_date,
	arv_start_date,
	arv_first_regimen,
	cur_arv_meds,
	cur_arv_line,
    first_evidence_patient_pregnant,
    edd,
	screened_for_tb,
	tb_tx_start_date,
	pcp_prophylaxis_start_date
from flat_moh_731_indicators_1);
