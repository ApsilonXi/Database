--
-- PostgreSQL database dump
--

-- Dumped from database version 17.4
-- Dumped by pg_dump version 17.4

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: convert_text_to_boolean(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.convert_text_to_boolean(text_value text, field_type text DEFAULT 'status'::text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
    text_value := LOWER(TRIM(text_value));
    
    -- Для типа накладной
    IF field_type = 'type' THEN
        RETURN text_value IN ('выгрузка', 'выгрузить', 'отправка', 'true', '1', 'да', 'yes', 'y');
    -- Для статуса
    ELSE
        RETURN text_value IN ('завершено', 'готово', 'выполнено', 'done', 'true', '1', 'да', 'yes', 'y');
    END IF;
END;
$$;


ALTER FUNCTION public.convert_text_to_boolean(text_value text, field_type text) OWNER TO postgres;

--
-- Name: delete_invoice_details_view(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_invoice_details_view() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    -- Удаляем связанные записи в правильном порядке (чтобы избежать нарушений ограничений внешнего ключа)
    
    -- 1. Удаляем связи с сотрудниками
    DELETE FROM invoice_employee WHERE invoiceID = OLD.invoice_id;
    
    -- 2. Удаляем детали накладной
    DELETE FROM invoice_detail WHERE invoiceID = OLD.invoice_id;
    
    -- 3. Удаляем саму накладную
    DELETE FROM invoice WHERE invoice_id = OLD.invoice_id;
    
    RETURN OLD;
END;
$$;


ALTER FUNCTION public.delete_invoice_details_view() OWNER TO postgres;

--
-- Name: delete_related_data(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_related_data() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    -- Для склада удаляем связанные комнаты, стеллажи, полки и детали
    IF TG_TABLE_NAME = 'warehouse' THEN
        -- Удаляем детали через отдельный запрос с явными правами
        PERFORM * FROM details WHERE shelfID IN (
            SELECT shelf_id FROM shelf WHERE rackID IN (
                SELECT rack_id FROM rack WHERE roomID IN (
                    SELECT room_id FROM room WHERE warehouseID = OLD.warehouse_id
                )
            )
        ) LIMIT 1;
        
        DELETE FROM shelf WHERE rackID IN (
            SELECT rack_id FROM rack WHERE roomID IN (
                SELECT room_id FROM room WHERE warehouseID = OLD.warehouse_id
            )
        );
        DELETE FROM rack WHERE roomID IN (
            SELECT room_id FROM room WHERE warehouseID = OLD.warehouse_id
        );
        DELETE FROM room WHERE warehouseID = OLD.warehouse_id;
    
    -- Для комнаты удаляем связанные стеллажи, полки и детали
    ELSIF TG_TABLE_NAME = 'room' THEN
        PERFORM * FROM details WHERE shelfID IN (
            SELECT shelf_id FROM shelf WHERE rackID IN (
                SELECT rack_id FROM rack WHERE roomID = OLD.room_id
            )
        ) LIMIT 1;
        
        DELETE FROM shelf WHERE rackID IN (
            SELECT rack_id FROM rack WHERE roomID = OLD.room_id
        );
        DELETE FROM rack WHERE roomID = OLD.room_id;
    
    -- Для стеллажа удаляем связанные полки и детали
    ELSIF TG_TABLE_NAME = 'rack' THEN
        PERFORM * FROM details WHERE shelfID IN (
            SELECT shelf_id FROM shelf WHERE rackID = OLD.rack_id
        ) LIMIT 1;
        
        DELETE FROM shelf WHERE rackID = OLD.rack_id;
    
    -- Для полки удаляем связанные детали
    ELSIF TG_TABLE_NAME = 'shelf' THEN
        PERFORM * FROM details WHERE shelfID = OLD.shelf_id LIMIT 1;
    END IF;
    RETURN OLD;
END;
$$;


ALTER FUNCTION public.delete_related_data() OWNER TO postgres;

--
-- Name: delete_warehouse_details(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_warehouse_details() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    warehouse_id_value integer;  -- Идентификатор склада
    room_id_value integer;       -- Идентификатор комнаты
    rack_id_value integer;       -- Идентификатор стеллажа
    shelf_id_value integer;      -- Идентификатор полки
BEGIN
    -- Получаем warehouse_id на основе warehouse_number
    SELECT w.warehouse_id INTO warehouse_id_value
    FROM warehouse w
    WHERE w.warehouse_number = OLD.warehouse_number;

    -- Получаем room_id на основе warehouse_id и room_number
    SELECT r.room_id INTO room_id_value
    FROM room r
    WHERE r.warehouseID = warehouse_id_value AND r.room_number = OLD.room_number;

    -- Получаем rack_id на основе room_id и rack_number
    SELECT ra.rack_id INTO rack_id_value
    FROM rack ra
    WHERE ra.roomID = room_id_value AND ra.rack_number = OLD.rack_number;

    -- Получаем shelf_id на основе rack_id и shelf_number
    SELECT s.shelf_id INTO shelf_id_value
    FROM shelf s
    WHERE s.rackID = rack_id_value AND s.shelf_number = OLD.shelf_number;

    -- Удаляем запись из таблицы details
    DELETE FROM details WHERE detail_id = OLD.detail_id;

    -- Удаляем запись из таблицы shelf, если на ней больше нет деталей
    DELETE FROM shelf 
    WHERE shelf.shelf_id = shelf_id_value
      AND NOT EXISTS (SELECT 1 FROM details WHERE details.shelfID = shelf.shelf_id);

    -- Удаляем запись из таблицы rack, если на стеллаже больше нет полок
    DELETE FROM rack 
    WHERE rack.rack_id = rack_id_value 
      AND NOT EXISTS (SELECT 1 FROM shelf WHERE shelf.rackID = rack.rack_id);

    -- Удаляем запись из таблицы room, если в комнате больше нет стеллажей
    DELETE FROM room 
    WHERE room.room_id = room_id_value 
      AND NOT EXISTS (SELECT 1 FROM rack WHERE rack.roomID = room.room_id);

    -- Удаляем запись из таблицы warehouse, если на складе больше нет комнат
    DELETE FROM warehouse 
    WHERE warehouse.warehouse_id = warehouse_id_value 
      AND NOT EXISTS (SELECT 1 FROM room WHERE room.warehouseID = warehouse.warehouse_id);

    RETURN OLD;
END;
$$;


ALTER FUNCTION public.delete_warehouse_details() OWNER TO postgres;

--
-- Name: get_employee_id(character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_employee_id(p_last_name character varying, p_first_name character varying, p_patronymic character varying) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_id integer;
BEGIN
    SELECT employee_id INTO v_id 
    FROM employee 
    WHERE last_name = p_last_name 
    AND first_name = p_first_name 
    AND patronymic = p_patronymic;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Сотрудник % % % не найден', 
            p_last_name, p_first_name, p_patronymic;
    END IF;
    
    RETURN v_id;
END;
$$;


ALTER FUNCTION public.get_employee_id(p_last_name character varying, p_first_name character varying, p_patronymic character varying) OWNER TO postgres;

--
-- Name: insert_into_warehouse_details(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.insert_into_warehouse_details() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    warehouse_id integer;
    room_id integer;
    rack_id integer;
    shelf_id integer;
BEGIN
    -- Добавляем запись в таблицу warehouse, если склад с таким номером не существует
    IF NOT EXISTS (SELECT 1 FROM warehouse WHERE warehouse_number = NEW.warehouse_number) THEN
        INSERT INTO warehouse (warehouse_number, address) 
        VALUES (NEW.warehouse_number, 'default address') 
        RETURNING warehouse.warehouse_id INTO warehouse_id;
    ELSE
        SELECT warehouse.warehouse_id INTO warehouse_id FROM warehouse WHERE warehouse_number = NEW.warehouse_number;
    END IF;

    -- Добавляем запись в таблицу room, если комната с таким номером не существует
    IF NOT EXISTS (SELECT 1 FROM room WHERE room_number = NEW.room_number AND warehouseID = warehouse_id) THEN
        INSERT INTO room (room_number, warehouseID) 
        VALUES (NEW.room_number, warehouse_id) 
        RETURNING room.room_id INTO room_id;
    ELSE
        SELECT room.room_id INTO room_id FROM room WHERE room_number = NEW.room_number AND warehouseID = warehouse_id;
    END IF;

    -- Добавляем запись в таблицу rack, если стеллаж с таким номером не существует
    IF NOT EXISTS (SELECT 1 FROM rack WHERE rack_number = NEW.rack_number AND roomID = room_id) THEN
        INSERT INTO rack (rack_number, roomID) 
        VALUES (NEW.rack_number, room_id) 
        RETURNING rack.rack_id INTO rack_id;
    ELSE
        SELECT rack.rack_id INTO rack_id FROM rack WHERE rack_number = NEW.rack_number AND roomID = room_id;
    END IF;

    -- Добавляем запись в таблицу shelf, если полка с таким номером не существует
    IF NOT EXISTS (SELECT 1 FROM shelf WHERE shelf_number = NEW.shelf_number AND rackID = rack_id) THEN
        INSERT INTO shelf (shelf_number, rackID) 
        VALUES (NEW.shelf_number, rack_id) 
        RETURNING shelf.shelf_id INTO shelf_id;
    ELSE
        SELECT shelf.shelf_id INTO shelf_id FROM shelf WHERE shelf_number = NEW.shelf_number AND rackID = rack_id;
    END IF;

    -- Добавляем деталь в таблицу details, связываем с полкой
    INSERT INTO details (shelfID, weight, type_detail) 
    VALUES (shelf_id, NEW.weight, NEW.type_detail);

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.insert_into_warehouse_details() OWNER TO postgres;

--
-- Name: insert_invoice_details_view(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.insert_invoice_details_view() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_invoice_id INTEGER;
    v_counteragent_id INTEGER;
    v_detail_id INTEGER;
    v_employee_id INTEGER;
    v_type_invoice BOOLEAN;
    v_status BOOLEAN;
BEGIN
    -- 1. Проверка и получение ID контрагента
    SELECT counteragent_id INTO v_counteragent_id 
    FROM counteragent 
    WHERE counteragent_name = NEW.counteragent_name;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Контрагент с именем % не найден', NEW.counteragent_name;
    END IF;

    -- 2. Преобразование текстовых значений в boolean
    IF NEW.type_invoice_text IS NOT NULL THEN
        v_type_invoice := convert_text_to_boolean(NEW.type_invoice_text, 'type');
    ELSE
        v_type_invoice := COALESCE(NEW.type_invoice_bool, FALSE);
    END IF;
    
    IF NEW.status_text IS NOT NULL THEN
        v_status := convert_text_to_boolean(NEW.status_text, 'status');
    ELSE
        v_status := COALESCE(NEW.status_bool, FALSE);
    END IF;

    -- 3. Обработка накладной (создание или обновление)
    IF NEW.invoice_id IS NOT NULL THEN
        -- Проверяем существование накладной
        PERFORM 1 FROM invoice WHERE invoice_id = NEW.invoice_id;
        
        IF FOUND THEN
            -- Обновляем существующую накладную
            UPDATE invoice SET
                counteragentID = v_counteragent_id,
                date_time = NEW.date_time,
                type_invoice = v_type_invoice,
                status = v_status
            WHERE invoice_id = NEW.invoice_id;
            
            v_invoice_id := NEW.invoice_id;
        ELSE
            -- Создаем новую накладную с указанным ID
            INSERT INTO invoice (invoice_id, counteragentID, date_time, type_invoice, status)
            VALUES (NEW.invoice_id, v_counteragent_id, NEW.date_time, v_type_invoice, v_status)
            RETURNING invoice_id INTO v_invoice_id;
        END IF;
    ELSE
        -- Создаем новую накладную без указания ID
        INSERT INTO invoice (counteragentID, date_time, type_invoice, status)
        VALUES (v_counteragent_id, NEW.date_time, v_type_invoice, v_status)
        RETURNING invoice_id INTO v_invoice_id;
    END IF;
    
    -- 4. Получаем ID детали
    SELECT detail_id INTO v_detail_id 
    FROM details 
    WHERE type_detail = NEW.type_detail;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Деталь типа % не найдена', NEW.type_detail;
    END IF;
    
    -- 5. Добавляем/обновляем деталь в накладной
    INSERT INTO invoice_detail (invoiceID, detailID, quantity)
    VALUES (v_invoice_id, v_detail_id, NEW.quantity)
    ON CONFLICT (invoiceID, detailID) 
    DO UPDATE SET quantity = invoice_detail.quantity + NEW.quantity;
    
    -- 6. Получаем ID сотрудника
    v_employee_id := get_employee_id(
        NEW.responsible_last_name, 
        NEW.responsible_first_name, 
        NEW.responsible_patronymic
    );
    
    -- 7. Связываем сотрудника с накладной
    INSERT INTO invoice_employee (invoiceID, responsible, granted_access, when_granted)
    VALUES (v_invoice_id, v_employee_id, v_employee_id, NOW())
    ON CONFLICT (invoiceID, responsible) DO NOTHING;
    
    -- 8. Возвращаем результат
    NEW.invoice_id := v_invoice_id;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.insert_invoice_details_view() OWNER TO postgres;

--
-- Name: log_counteragent_changes(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.log_counteragent_changes() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO log_table (table_name, action_type, record_id, new_values)
        VALUES ('counteragent', 'INSERT', NEW.counteragent_id, to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'UPDATE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values, new_values)
        VALUES ('counteragent', 'UPDATE', OLD.counteragent_id, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'DELETE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values)
        VALUES ('counteragent', 'DELETE', OLD.counteragent_id, to_jsonb(OLD));
        RETURN OLD;
    END IF;
END;
$$;


ALTER FUNCTION public.log_counteragent_changes() OWNER TO postgres;

--
-- Name: log_details_changes(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.log_details_changes() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO log_table (table_name, action_type, record_id, new_values)
        VALUES ('details', 'INSERT', NEW.detail_id, to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'UPDATE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values, new_values)
        VALUES ('details', 'UPDATE', OLD.detail_id, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'DELETE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values)
        VALUES ('details', 'DELETE', OLD.detail_id, to_jsonb(OLD));
        RETURN OLD;
    END IF;
END;
$$;


ALTER FUNCTION public.log_details_changes() OWNER TO postgres;

--
-- Name: log_employee_changes(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.log_employee_changes() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO log_table (table_name, action_type, record_id, new_values)
        VALUES ('employee', 'INSERT', NEW.employee_id, to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'UPDATE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values, new_values)
        VALUES ('employee', 'UPDATE', OLD.employee_id, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'DELETE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values)
        VALUES ('employee', 'DELETE', OLD.employee_id, to_jsonb(OLD));
        RETURN OLD;
    END IF;
END;
$$;


ALTER FUNCTION public.log_employee_changes() OWNER TO postgres;

--
-- Name: log_invoice_changes(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.log_invoice_changes() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO log_table (table_name, action_type, record_id, new_values)
        VALUES ('invoice', 'INSERT', NEW.invoice_id, to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'UPDATE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values, new_values)
        VALUES ('invoice', 'UPDATE', OLD.invoice_id, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'DELETE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values)
        VALUES ('invoice', 'DELETE', OLD.invoice_id, to_jsonb(OLD));
        RETURN OLD;
    END IF;
END;
$$;


ALTER FUNCTION public.log_invoice_changes() OWNER TO postgres;

--
-- Name: log_invoice_detail_changes(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.log_invoice_detail_changes() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO log_table (table_name, action_type, record_id, new_values)
        VALUES ('invoice_detail', 'INSERT', NEW.invoiceID, to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'UPDATE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values, new_values)
        VALUES ('invoice_detail', 'UPDATE', OLD.invoiceID, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'DELETE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values)
        VALUES ('invoice_detail', 'DELETE', OLD.invoiceID, to_jsonb(OLD));
        RETURN OLD;
    END IF;
END;
$$;


ALTER FUNCTION public.log_invoice_detail_changes() OWNER TO postgres;

--
-- Name: log_invoice_employee_changes(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.log_invoice_employee_changes() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO log_table (table_name, action_type, record_id, new_values)
        VALUES ('invoice_employee', 'INSERT', NEW.invoiceID, to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'UPDATE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values, new_values)
        VALUES ('invoice_employee', 'UPDATE', OLD.invoiceID, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'DELETE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values)
        VALUES ('invoice_employee', 'DELETE', OLD.invoiceID, to_jsonb(OLD));
        RETURN OLD;
    END IF;
END;
$$;


ALTER FUNCTION public.log_invoice_employee_changes() OWNER TO postgres;

--
-- Name: log_rack_changes(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.log_rack_changes() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO log_table (table_name, action_type, record_id, new_values)
        VALUES ('rack', 'INSERT', NEW.rack_id, to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'UPDATE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values, new_values)
        VALUES ('rack', 'UPDATE', OLD.rack_id, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'DELETE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values)
        VALUES ('rack', 'DELETE', OLD.rack_id, to_jsonb(OLD));
        RETURN OLD;
    END IF;
END;
$$;


ALTER FUNCTION public.log_rack_changes() OWNER TO postgres;

--
-- Name: log_room_changes(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.log_room_changes() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO log_table (table_name, action_type, record_id, new_values)
        VALUES ('room', 'INSERT', NEW.room_id, to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'UPDATE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values, new_values)
        VALUES ('room', 'UPDATE', OLD.room_id, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'DELETE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values)
        VALUES ('room', 'DELETE', OLD.room_id, to_jsonb(OLD));
        RETURN OLD;
    END IF;
END;
$$;


ALTER FUNCTION public.log_room_changes() OWNER TO postgres;

--
-- Name: log_shelf_changes(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.log_shelf_changes() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO log_table (table_name, action_type, record_id, new_values)
        VALUES ('shelf', 'INSERT', NEW.shelf_id, to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'UPDATE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values, new_values)
        VALUES ('shelf', 'UPDATE', OLD.shelf_id, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'DELETE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values)
        VALUES ('shelf', 'DELETE', OLD.shelf_id, to_jsonb(OLD));
        RETURN OLD;
    END IF;
END;
$$;


ALTER FUNCTION public.log_shelf_changes() OWNER TO postgres;

--
-- Name: log_warehouse_changes(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.log_warehouse_changes() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO log_table (table_name, action_type, record_id, new_values)
        VALUES ('warehouse', 'INSERT', NEW.warehouse_id, to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'UPDATE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values, new_values)
        VALUES ('warehouse', 'UPDATE', OLD.warehouse_id, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'DELETE') THEN
        INSERT INTO log_table (table_name, action_type, record_id, old_values)
        VALUES ('warehouse', 'DELETE', OLD.warehouse_id, to_jsonb(OLD));
        RETURN OLD;
    END IF;
END;
$$;


ALTER FUNCTION public.log_warehouse_changes() OWNER TO postgres;

--
-- Name: update_invoice_details_view(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_invoice_details_view() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_updated BOOLEAN := FALSE;
BEGIN
    -- 1. Если обновляется тип накладной (через текстовое поле)
    IF NEW.type_invoice_text IS DISTINCT FROM OLD.type_invoice_text THEN
        UPDATE invoice SET 
            type_invoice = convert_text_to_boolean(NEW.type_invoice_text, 'type')
        WHERE invoice_id = NEW.invoice_id;
        v_updated := TRUE;
    END IF;
    
    -- 2. Если обновляется статус (через текстовое поле)
    IF NEW.status_text IS DISTINCT FROM OLD.status_text THEN
        UPDATE invoice SET 
            status = convert_text_to_boolean(NEW.status_text, 'status')
        WHERE invoice_id = NEW.invoice_id;
        v_updated := TRUE;
    END IF;
    
    -- 3. Проверяем, что не пытаются изменить другие поля
    IF NOT v_updated AND (
        NEW.invoice_id IS DISTINCT FROM OLD.invoice_id OR
        NEW.counteragent_name IS DISTINCT FROM OLD.counteragent_name OR
        NEW.date_time IS DISTINCT FROM OLD.date_time OR
        NEW.type_detail IS DISTINCT FROM OLD.type_detail OR
        NEW.quantity IS DISTINCT FROM OLD.quantity OR
        NEW.responsible_last_name IS DISTINCT FROM OLD.responsible_last_name OR
        NEW.responsible_first_name IS DISTINCT FROM OLD.responsible_first_name OR
        NEW.responsible_patronymic IS DISTINCT FROM OLD.responsible_patronymic
    ) THEN
        RAISE EXCEPTION 'Разрешено обновлять только поля type_invoice_text и status_text';
    END IF;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_invoice_details_view() OWNER TO postgres;

--
-- Name: update_invoice_status(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_invoice_status() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    -- Разрешаем обновлять только поле status
    IF TG_OP = 'UPDATE' AND (
        OLD.invoice_id IS DISTINCT FROM NEW.invoice_id OR
        OLD.counteragent_name IS DISTINCT FROM NEW.counteragent_name OR
        OLD.date_time IS DISTINCT FROM NEW.date_time OR
        OLD.type_invoice IS DISTINCT FROM NEW.type_invoice OR
        OLD.type_detail IS DISTINCT FROM NEW.type_detail OR
        OLD.quantity IS DISTINCT FROM NEW.quantity OR
        OLD.responsible_last_name IS DISTINCT FROM NEW.responsible_last_name OR
        OLD.responsible_first_name IS DISTINCT FROM NEW.responsible_first_name OR
        OLD.responsible_patronymic IS DISTINCT FROM NEW.responsible_patronymic OR
        OLD.responsible_id IS DISTINCT FROM NEW.responsible_id
    ) THEN
        RAISE EXCEPTION 'Разрешено обновлять только поле status. Попытка изменить другие поля запрещена.';
    END IF;
    
    -- Проверяем, что статус действительно изменился
    IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
        RETURN NEW; -- Ничего не делаем, если статус не изменился
    END IF;
    
    -- Обновляем статус в основной таблице
    UPDATE invoice SET status = NEW.status 
    WHERE invoice_id = NEW.invoice_id;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_invoice_status() OWNER TO postgres;

--
-- Name: update_warehouse_details_view(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_warehouse_details_view() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Обновляем таблицу details
    UPDATE details
    SET type_detail = NEW.type_detail, weight = NEW.weight
    WHERE detail_id = OLD.detail_id;

    -- Обновляем таблицу shelf
    UPDATE shelf
    SET shelf_number = NEW.shelf_number
    WHERE shelf_id = (SELECT shelfID FROM details WHERE detail_id = OLD.detail_id);

    -- Обновляем таблицу rack
    UPDATE rack
    SET rack_number = NEW.rack_number
    WHERE rack_id = (SELECT rackID FROM shelf WHERE shelf_id = (SELECT shelfID FROM details WHERE detail_id = OLD.detail_id));

    -- Обновляем таблицу room
    UPDATE room
    SET room_number = NEW.room_number
    WHERE room_id = (SELECT roomID FROM rack WHERE rack_id = (SELECT rackID FROM shelf WHERE shelf_id = (SELECT shelfID FROM details WHERE detail_id = OLD.detail_id)));

    -- Обновляем таблицу warehouse
    UPDATE warehouse
    SET warehouse_number = NEW.warehouse_number
    WHERE warehouse_id = (SELECT warehouseID FROM room WHERE room_id = (SELECT roomID FROM rack WHERE rack_id = (SELECT rackID FROM shelf WHERE shelf_id = (SELECT shelfID FROM details WHERE detail_id = OLD.detail_id))));

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_warehouse_details_view() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: counteragent; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.counteragent (
    counteragent_id integer NOT NULL,
    counteragent_name character varying(128) NOT NULL,
    contact_person character varying(128) NOT NULL,
    phone_number bigint NOT NULL,
    address text NOT NULL
);


ALTER TABLE public.counteragent OWNER TO postgres;

--
-- Name: counteragent_counteragent_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.counteragent_counteragent_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.counteragent_counteragent_id_seq OWNER TO postgres;

--
-- Name: counteragent_counteragent_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.counteragent_counteragent_id_seq OWNED BY public.counteragent.counteragent_id;


--
-- Name: details; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.details (
    detail_id integer NOT NULL,
    shelfid integer NOT NULL,
    weight double precision NOT NULL,
    type_detail text NOT NULL
);


ALTER TABLE public.details OWNER TO postgres;

--
-- Name: details_detail_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.details_detail_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.details_detail_id_seq OWNER TO postgres;

--
-- Name: details_detail_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.details_detail_id_seq OWNED BY public.details.detail_id;


--
-- Name: details_shelfid_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.details_shelfid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.details_shelfid_seq OWNER TO postgres;

--
-- Name: details_shelfid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.details_shelfid_seq OWNED BY public.details.shelfid;


--
-- Name: employee; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.employee (
    employee_id integer NOT NULL,
    employee_role character varying(25) NOT NULL,
    last_name character varying(35) NOT NULL,
    first_name character varying(35) NOT NULL,
    patronymic character varying(35) NOT NULL
);


ALTER TABLE public.employee OWNER TO postgres;

--
-- Name: employee_employee_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.employee_employee_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.employee_employee_id_seq OWNER TO postgres;

--
-- Name: employee_employee_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.employee_employee_id_seq OWNED BY public.employee.employee_id;


--
-- Name: invoice; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.invoice (
    invoice_id integer NOT NULL,
    counteragentid integer NOT NULL,
    date_time timestamp without time zone NOT NULL,
    type_invoice boolean NOT NULL,
    status boolean NOT NULL
);


ALTER TABLE public.invoice OWNER TO postgres;

--
-- Name: invoice_counteragentid_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.invoice_counteragentid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.invoice_counteragentid_seq OWNER TO postgres;

--
-- Name: invoice_counteragentid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.invoice_counteragentid_seq OWNED BY public.invoice.counteragentid;


--
-- Name: invoice_detail; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.invoice_detail (
    invoiceid integer NOT NULL,
    detailid integer NOT NULL,
    quantity integer NOT NULL
);


ALTER TABLE public.invoice_detail OWNER TO postgres;

--
-- Name: invoice_detail_detailid_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.invoice_detail_detailid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.invoice_detail_detailid_seq OWNER TO postgres;

--
-- Name: invoice_detail_detailid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.invoice_detail_detailid_seq OWNED BY public.invoice_detail.detailid;


--
-- Name: invoice_detail_invoiceid_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.invoice_detail_invoiceid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.invoice_detail_invoiceid_seq OWNER TO postgres;

--
-- Name: invoice_detail_invoiceid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.invoice_detail_invoiceid_seq OWNED BY public.invoice_detail.invoiceid;


--
-- Name: invoice_employee; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.invoice_employee (
    invoiceid integer NOT NULL,
    responsible integer NOT NULL,
    granted_access integer NOT NULL,
    when_granted timestamp without time zone NOT NULL
);


ALTER TABLE public.invoice_employee OWNER TO postgres;

--
-- Name: invoice_details_view; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.invoice_details_view AS
 SELECT inv.invoice_id,
    ca.counteragent_name,
    inv.date_time,
        CASE
            WHEN inv.type_invoice THEN 'Выгрузка'::text
            ELSE 'Отгрузка'::text
        END AS type_invoice_text,
        CASE
            WHEN inv.status THEN 'Завершено'::text
            ELSE 'В процессе'::text
        END AS status_text,
    det.type_detail,
    invd.quantity,
    emp.last_name AS responsible_last_name,
    emp.first_name AS responsible_first_name,
    emp.patronymic AS responsible_patronymic,
    emp.employee_id AS responsible_id,
    inv.status AS status_bool,
    inv.type_invoice AS type_invoice_bool
   FROM (((((public.invoice inv
     JOIN public.invoice_detail invd ON ((inv.invoice_id = invd.invoiceid)))
     JOIN public.details det ON ((invd.detailid = det.detail_id)))
     JOIN public.invoice_employee inv_emp ON ((inv.invoice_id = inv_emp.invoiceid)))
     JOIN public.employee emp ON ((inv_emp.responsible = emp.employee_id)))
     JOIN public.counteragent ca ON ((inv.counteragentid = ca.counteragent_id)));


ALTER VIEW public.invoice_details_view OWNER TO postgres;

--
-- Name: invoice_employee_granted_access_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.invoice_employee_granted_access_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.invoice_employee_granted_access_seq OWNER TO postgres;

--
-- Name: invoice_employee_granted_access_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.invoice_employee_granted_access_seq OWNED BY public.invoice_employee.granted_access;


--
-- Name: invoice_employee_invoiceid_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.invoice_employee_invoiceid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.invoice_employee_invoiceid_seq OWNER TO postgres;

--
-- Name: invoice_employee_invoiceid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.invoice_employee_invoiceid_seq OWNED BY public.invoice_employee.invoiceid;


--
-- Name: invoice_employee_responsible_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.invoice_employee_responsible_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.invoice_employee_responsible_seq OWNER TO postgres;

--
-- Name: invoice_employee_responsible_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.invoice_employee_responsible_seq OWNED BY public.invoice_employee.responsible;


--
-- Name: invoice_invoice_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.invoice_invoice_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.invoice_invoice_id_seq OWNER TO postgres;

--
-- Name: invoice_invoice_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.invoice_invoice_id_seq OWNED BY public.invoice.invoice_id;


--
-- Name: log_table; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.log_table (
    log_id integer NOT NULL,
    table_name character varying(50) NOT NULL,
    action_type character varying(20) NOT NULL,
    record_id integer,
    action_time timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    old_values jsonb,
    new_values jsonb
);


ALTER TABLE public.log_table OWNER TO postgres;

--
-- Name: log_table_log_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.log_table_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.log_table_log_id_seq OWNER TO postgres;

--
-- Name: log_table_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.log_table_log_id_seq OWNED BY public.log_table.log_id;


--
-- Name: rack; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.rack (
    rack_id integer NOT NULL,
    roomid integer NOT NULL,
    rack_number integer NOT NULL
);


ALTER TABLE public.rack OWNER TO postgres;

--
-- Name: rack_rack_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.rack_rack_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.rack_rack_id_seq OWNER TO postgres;

--
-- Name: rack_rack_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.rack_rack_id_seq OWNED BY public.rack.rack_id;


--
-- Name: rack_roomid_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.rack_roomid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.rack_roomid_seq OWNER TO postgres;

--
-- Name: rack_roomid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.rack_roomid_seq OWNED BY public.rack.roomid;


--
-- Name: room; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.room (
    room_id integer NOT NULL,
    warehouseid integer NOT NULL,
    room_number integer NOT NULL
);


ALTER TABLE public.room OWNER TO postgres;

--
-- Name: room_room_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.room_room_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.room_room_id_seq OWNER TO postgres;

--
-- Name: room_room_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.room_room_id_seq OWNED BY public.room.room_id;


--
-- Name: room_warehouseid_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.room_warehouseid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.room_warehouseid_seq OWNER TO postgres;

--
-- Name: room_warehouseid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.room_warehouseid_seq OWNED BY public.room.warehouseid;


--
-- Name: shelf; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.shelf (
    shelf_id integer NOT NULL,
    rackid integer NOT NULL,
    shelf_number integer NOT NULL
);


ALTER TABLE public.shelf OWNER TO postgres;

--
-- Name: shelf_rackid_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.shelf_rackid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.shelf_rackid_seq OWNER TO postgres;

--
-- Name: shelf_rackid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.shelf_rackid_seq OWNED BY public.shelf.rackid;


--
-- Name: shelf_shelf_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.shelf_shelf_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.shelf_shelf_id_seq OWNER TO postgres;

--
-- Name: shelf_shelf_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.shelf_shelf_id_seq OWNED BY public.shelf.shelf_id;


--
-- Name: warehouse; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.warehouse (
    warehouse_id integer NOT NULL,
    warehouse_number integer NOT NULL,
    address text NOT NULL
);


ALTER TABLE public.warehouse OWNER TO postgres;

--
-- Name: warehouse_details_view; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.warehouse_details_view AS
 SELECT w.warehouse_number,
    r.room_number,
    rk.rack_number,
    s.shelf_number,
    d.type_detail,
    d.weight,
    d.detail_id
   FROM ((((public.warehouse w
     JOIN public.room r ON ((w.warehouse_id = r.warehouseid)))
     JOIN public.rack rk ON ((r.room_id = rk.roomid)))
     JOIN public.shelf s ON ((rk.rack_id = s.rackid)))
     JOIN public.details d ON ((s.shelf_id = d.shelfid)));


ALTER VIEW public.warehouse_details_view OWNER TO postgres;

--
-- Name: warehouse_warehouse_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.warehouse_warehouse_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.warehouse_warehouse_id_seq OWNER TO postgres;

--
-- Name: warehouse_warehouse_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.warehouse_warehouse_id_seq OWNED BY public.warehouse.warehouse_id;


--
-- Name: counteragent counteragent_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.counteragent ALTER COLUMN counteragent_id SET DEFAULT nextval('public.counteragent_counteragent_id_seq'::regclass);


--
-- Name: details detail_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.details ALTER COLUMN detail_id SET DEFAULT nextval('public.details_detail_id_seq'::regclass);


--
-- Name: details shelfid; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.details ALTER COLUMN shelfid SET DEFAULT nextval('public.details_shelfid_seq'::regclass);


--
-- Name: employee employee_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.employee ALTER COLUMN employee_id SET DEFAULT nextval('public.employee_employee_id_seq'::regclass);


--
-- Name: invoice invoice_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.invoice ALTER COLUMN invoice_id SET DEFAULT nextval('public.invoice_invoice_id_seq'::regclass);


--
-- Name: invoice counteragentid; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.invoice ALTER COLUMN counteragentid SET DEFAULT nextval('public.invoice_counteragentid_seq'::regclass);


--
-- Name: invoice_detail invoiceid; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.invoice_detail ALTER COLUMN invoiceid SET DEFAULT nextval('public.invoice_detail_invoiceid_seq'::regclass);


--
-- Name: invoice_detail detailid; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.invoice_detail ALTER COLUMN detailid SET DEFAULT nextval('public.invoice_detail_detailid_seq'::regclass);


--
-- Name: invoice_employee invoiceid; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.invoice_employee ALTER COLUMN invoiceid SET DEFAULT nextval('public.invoice_employee_invoiceid_seq'::regclass);


--
-- Name: invoice_employee responsible; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.invoice_employee ALTER COLUMN responsible SET DEFAULT nextval('public.invoice_employee_responsible_seq'::regclass);


--
-- Name: invoice_employee granted_access; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.invoice_employee ALTER COLUMN granted_access SET DEFAULT nextval('public.invoice_employee_granted_access_seq'::regclass);


--
-- Name: log_table log_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.log_table ALTER COLUMN log_id SET DEFAULT nextval('public.log_table_log_id_seq'::regclass);


--
-- Name: rack rack_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.rack ALTER COLUMN rack_id SET DEFAULT nextval('public.rack_rack_id_seq'::regclass);


--
-- Name: rack roomid; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.rack ALTER COLUMN roomid SET DEFAULT nextval('public.rack_roomid_seq'::regclass);


--
-- Name: room room_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.room ALTER COLUMN room_id SET DEFAULT nextval('public.room_room_id_seq'::regclass);


--
-- Name: room warehouseid; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.room ALTER COLUMN warehouseid SET DEFAULT nextval('public.room_warehouseid_seq'::regclass);


--
-- Name: shelf shelf_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.shelf ALTER COLUMN shelf_id SET DEFAULT nextval('public.shelf_shelf_id_seq'::regclass);


--
-- Name: shelf rackid; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.shelf ALTER COLUMN rackid SET DEFAULT nextval('public.shelf_rackid_seq'::regclass);


--
-- Name: warehouse warehouse_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouse ALTER COLUMN warehouse_id SET DEFAULT nextval('public.warehouse_warehouse_id_seq'::regclass);


--
-- Data for Name: counteragent; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.counteragent (counteragent_id, counteragent_name, contact_person, phone_number, address) FROM stdin;
2	ЗАО "ТехЗапчасть"	Анна Смирнова	2345678901	ул. Рыночная, 2, Город B
3	ООО "МоторТехника"	Алексей Сидоров	3456789012	проспект Инноваций, 3, Город C
4	ИП "АвтоМир"	Мария Кузнецова	4567890123	ул. Стиля, 4, Город D
5	ООО "Детали и Механизмы"	Ольга Павлова	5678901234	ул. Уютная, 5, Город E
1	ООО "АвтоЗапчасти"	Иван Иванов	1234567890	ул. Бизнеса, 1, Город A
\.


--
-- Data for Name: details; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.details (detail_id, shelfid, weight, type_detail) FROM stdin;
5	5	15.2	Шины
7	18	5	Тормозные колодки
8	7	20.7	Подвеска
10	21	15.2	Шины
11	21	12.5	Двигатель
12	22	5	Тормозные колодки
13	23	20.7	Подвеска
15	25	15.2	Шины
16	8	12.5	Коробка передач
17	9	5	Карданный вал
18	10	20.7	Радиатор
19	11	7.3	Генератор
20	12	15.2	Стартер
21	13	12.5	Поршень
26	45	12.5	Выхлопная система
39	1	1	Полуось
6	11	12.4	Двигатель
14	24	7.3	Фары
9	19	7.3	Фары
4	4	7.3	Фары
3	3	20.7	Подвеска
2	2	5	Тормозные колодки
1	31	12	Двигатель
\.


--
-- Data for Name: employee; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.employee (employee_id, employee_role, last_name, first_name, patronymic) FROM stdin;
1	Кладовщик	Иванов	Иван	Иванович
2	Менеджер склада	Петров	Петр	Петрович
3	Владелец	Сидоров	Сидр	Сидорович
4	Кладовщик	Федоров	Федор	Федорович
5	Менеджер склада	Смирнов	Сергей	Сергеевич
\.


--
-- Data for Name: invoice; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.invoice (invoice_id, counteragentid, date_time, type_invoice, status) FROM stdin;
10	3	2025-03-29 18:35:00	t	f
12	5	2025-03-29 22:13:00	f	f
3	3	2025-03-03 14:45:00	t	t
7	3	2025-03-28 01:37:00	f	f
6	1	2025-03-28 01:33:00	f	f
1	1	2025-03-01 09:00:00	t	f
2	2	2025-03-02 10:30:00	f	f
4	4	2025-03-04 11:20:00	f	f
5	5	2025-03-05 15:00:00	t	t
\.


--
-- Data for Name: invoice_detail; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.invoice_detail (invoiceid, detailid, quantity) FROM stdin;
12	20	1
3	3	1
7	39	1
6	26	1
1	11	3
2	2	2
4	4	2
5	5	2
\.


--
-- Data for Name: invoice_employee; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.invoice_employee (invoiceid, responsible, granted_access, when_granted) FROM stdin;
12	3	3	2025-03-29 22:13:00.411972
3	2	5	2025-03-03 14:50:00
7	2	2	2025-03-28 01:36:18.328025
6	1	1	2025-03-28 01:33:02.845495
1	1	2	2025-03-01 09:05:00
2	3	4	2025-03-02 10:35:00
4	4	1	2025-03-04 11:25:00
5	5	3	2025-03-05 15:05:00
\.


--
-- Data for Name: log_table; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.log_table (log_id, table_name, action_type, record_id, action_time, old_values, new_values) FROM stdin;
1	details	UPDATE	39	2025-03-28 03:15:48.796584	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 1, "detail_id": 39, "type_detail": "Полуось"}
2	details	UPDATE	39	2025-03-28 03:15:53.290396	{"weight": 1, "shelfid": 1, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}
3	SYSTEM	UNDO	1	2025-03-28 03:15:53.290396	\N	\N
4	details	UPDATE	39	2025-03-28 03:15:55.784415	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 1, "detail_id": 39, "type_detail": "Полуось"}
5	SYSTEM	UNDO	2	2025-03-28 03:15:55.784415	\N	\N
6	details	UPDATE	39	2025-03-28 03:15:58.484176	{"weight": 1, "shelfid": 1, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}
7	SYSTEM	UNDO	4	2025-03-28 03:15:58.484176	\N	\N
8	details	UPDATE	39	2025-03-28 03:16:01.226717	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}
9	details	UPDATE	39	2025-03-28 03:16:01.226717	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 1, "detail_id": 39, "type_detail": "Полуось"}
10	details	UPDATE	39	2025-03-28 03:16:01.226717	{"weight": 1, "shelfid": 1, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}
11	details	UPDATE	39	2025-03-28 03:16:01.226717	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 1, "detail_id": 39, "type_detail": "Полуось"}
12	SYSTEM	ROLLBACK	7	2025-03-28 03:16:01.226717	\N	\N
13	invoice	UPDATE	9	2025-03-28 03:16:22.648426	{"status": false, "date_time": "2025-03-28T02:00:00", "invoice_id": 9, "type_invoice": false, "counteragentid": 2}	{"status": false, "date_time": "2025-03-28T02:00:00", "invoice_id": 9, "type_invoice": false, "counteragentid": 2}
14	invoice_detail	UPDATE	9	2025-03-28 03:16:22.648426	{"detailid": 4, "quantity": 10, "invoiceid": 9}	{"detailid": 4, "quantity": 1, "invoiceid": 9}
15	invoice_employee	UPDATE	9	2025-03-28 03:16:22.648426	{"invoiceid": 9, "responsible": 2, "when_granted": "2025-03-28T02:00:43.000485", "granted_access": 2}	{"invoiceid": 9, "responsible": 2, "when_granted": "2025-03-28T02:00:43.000485", "granted_access": 2}
16	invoice	UPDATE	9	2025-03-28 03:18:57.883094	{"status": false, "date_time": "2025-03-28T02:00:00", "invoice_id": 9, "type_invoice": false, "counteragentid": 2}	{"status": false, "date_time": "2025-03-28T02:00:00", "invoice_id": 9, "type_invoice": false, "counteragentid": 2}
17	invoice_detail	UPDATE	9	2025-03-28 03:18:57.883094	{"detailid": 4, "quantity": 1, "invoiceid": 9}	{"detailid": 4, "quantity": 10, "invoiceid": 9}
18	invoice_employee	UPDATE	9	2025-03-28 03:18:57.883094	{"invoiceid": 9, "responsible": 2, "when_granted": "2025-03-28T02:00:43.000485", "granted_access": 2}	{"invoiceid": 9, "responsible": 2, "when_granted": "2025-03-28T02:00:43.000485", "granted_access": 2}
20	SYSTEM	ROLLBACK	3	2025-03-28 03:19:06.491059	\N	\N
21	invoice	UPDATE	9	2025-03-28 03:19:19.170891	{"status": false, "date_time": "2025-03-28T02:00:00", "invoice_id": 9, "type_invoice": false, "counteragentid": 2}	{"status": false, "date_time": "2025-03-28T02:00:00", "invoice_id": 9, "type_invoice": false, "counteragentid": 2}
22	invoice_detail	UPDATE	9	2025-03-28 03:19:19.170891	{"detailid": 4, "quantity": 10, "invoiceid": 9}	{"detailid": 4, "quantity": 1, "invoiceid": 9}
23	invoice_employee	UPDATE	9	2025-03-28 03:19:19.170891	{"invoiceid": 9, "responsible": 2, "when_granted": "2025-03-28T02:00:43.000485", "granted_access": 2}	{"invoiceid": 9, "responsible": 2, "when_granted": "2025-03-28T02:00:43.000485", "granted_access": 2}
24	invoice	UPDATE	1	2025-03-28 03:21:30.6669	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
26	invoice	UPDATE	1	2025-03-28 03:21:49.22523	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
28	invoice	UPDATE	1	2025-03-28 03:21:54.003687	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
29	invoice	UPDATE	1	2025-03-28 03:21:54.003687	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
30	SYSTEM	ROLLBACK	2	2025-03-28 03:21:54.003687	\N	\N
31	invoice	UPDATE	1	2025-03-28 03:21:54.007389	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
32	invoice	UPDATE	1	2025-03-28 03:22:01.137824	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
33	SYSTEM	ROLLBACK	1	2025-03-28 03:22:01.137824	\N	\N
34	invoice	UPDATE	9	2025-03-28 03:22:21.203335	{"status": false, "date_time": "2025-03-28T02:00:00", "invoice_id": 9, "type_invoice": false, "counteragentid": 2}	{"status": false, "date_time": "2025-03-28T02:00:00", "invoice_id": 9, "type_invoice": false, "counteragentid": 2}
35	invoice_detail	UPDATE	9	2025-03-28 03:22:21.203335	{"detailid": 4, "quantity": 1, "invoiceid": 9}	{"detailid": 4, "quantity": 10, "invoiceid": 9}
36	invoice_employee	UPDATE	9	2025-03-28 03:22:21.203335	{"invoiceid": 9, "responsible": 2, "when_granted": "2025-03-28T02:00:43.000485", "granted_access": 2}	{"invoiceid": 9, "responsible": 2, "when_granted": "2025-03-28T02:00:43.000485", "granted_access": 2}
38	SYSTEM	ROLLBACK	3	2025-03-28 03:22:38.119698	\N	\N
39	invoice	UPDATE	1	2025-03-28 03:23:31.47833	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
41	invoice	UPDATE	1	2025-03-28 03:23:43.778075	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
42	SYSTEM	ROLLBACK	1	2025-03-28 03:23:43.778075	\N	\N
43	invoice	UPDATE	1	2025-03-28 03:23:43.781277	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
48	invoice	UPDATE	1	2025-03-28 03:30:34.098023	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
49	invoice	UPDATE	1	2025-03-28 03:30:34.098023	{"status": false}	{"status": true}
50	invoice	UPDATE	1	2025-03-28 03:32:40.469384	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
51	invoice	UPDATE	1	2025-03-28 03:32:40.469384	{"status": true}	{"status": false}
52	invoice	UPDATE	1	2025-03-28 03:32:51.017218	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
53	invoice	UPDATE	1	2025-03-28 03:32:51.017218	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
54	SYSTEM	ROLLBACK	2	2025-03-28 03:32:51.017218	\N	\N
55	invoice	UPDATE	1	2025-03-28 03:33:13.197985	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
56	invoice	UPDATE	1	2025-03-28 03:33:13.197985	{"status": true}	{"status": false}
57	invoice	UPDATE	1	2025-03-28 03:35:09.939822	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
58	invoice	UPDATE	1	2025-03-28 03:35:09.939822	{"status": false}	{"status": true}
59	details	UPDATE	39	2025-03-28 03:35:42.929413	{"weight": 1, "shelfid": 1, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}
60	details	UPDATE	39	2025-03-28 03:36:08.197651	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 1, "detail_id": 39, "type_detail": "Полуось"}
62	details	UPDATE	39	2025-03-28 03:36:28.461873	{"weight": 1, "shelfid": 1, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}
64	details	UPDATE	39	2025-03-28 03:36:46.893471	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 1, "detail_id": 39, "type_detail": "Полуось"}
65	details	UPDATE	39	2025-03-28 03:36:50.596713	{"weight": 1, "shelfid": 1, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}
66	details	UNDO	64	2025-03-28 03:36:50.596713	{"weight": 1, "shelfid": 1, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}
67	details	UPDATE	39	2025-03-28 03:36:52.615277	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}
68	details	UPDATE	39	2025-03-28 03:36:52.615277	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 1, "detail_id": 39, "type_detail": "Полуось"}
69	SYSTEM	ROLLBACK	3	2025-03-28 03:36:52.615277	\N	\N
70	details	UPDATE	39	2025-03-28 03:36:56.140132	{"weight": 1, "shelfid": 1, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}
71	details	UNDO	68	2025-03-28 03:36:56.140132	{"weight": 1, "shelfid": 1, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}
72	details	UPDATE	39	2025-03-28 03:37:04.396555	{"weight": 1, "shelfid": 26, "detail_id": 39, "type_detail": "Полуось"}	{"weight": 1, "shelfid": 1, "detail_id": 39, "type_detail": "Полуось"}
73	SYSTEM	ROLLBACK	2	2025-03-28 03:37:04.396555	\N	\N
74	invoice	UPDATE	1	2025-03-28 03:37:08.001088	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
75	invoice	UPDATE	1	2025-03-28 03:37:14.905593	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
76	invoice	UNDO	74	2025-03-28 03:37:14.905593	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
77	invoice	UPDATE	1	2025-03-28 03:37:16.955625	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
78	invoice	UPDATE	1	2025-03-28 03:37:22.873537	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
79	invoice	UNDO	77	2025-03-28 03:37:22.873537	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
80	invoice	UPDATE	1	2025-03-28 03:37:24.972851	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
81	invoice	UPDATE	1	2025-03-28 03:37:24.972851	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
82	invoice	UPDATE	1	2025-03-28 03:37:24.972851	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
83	invoice	UPDATE	1	2025-03-28 03:37:24.972851	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
84	SYSTEM	ROLLBACK	6	2025-03-28 03:37:24.972851	\N	\N
85	invoice	UPDATE	1	2025-03-28 03:37:38.058044	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": false, "counteragentid": 1}
86	invoice_detail	UPDATE	1	2025-03-28 03:37:38.058044	{"detailid": 6, "quantity": 10, "invoiceid": 1}	{"detailid": 6, "quantity": 10, "invoiceid": 1}
87	invoice_employee	UPDATE	1	2025-03-28 03:37:38.058044	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}
89	SYSTEM	ROLLBACK	3	2025-03-28 03:37:48.32742	\N	\N
90	invoice	UPDATE	1	2025-03-28 03:37:48.330638	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": false, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
91	invoice_detail	UPDATE	1	2025-03-28 03:37:48.330638	{"detailid": 6, "quantity": 10, "invoiceid": 1}	{"detailid": 6, "quantity": 10, "invoiceid": 1}
92	invoice_employee	UPDATE	1	2025-03-28 03:37:48.330638	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}
94	SYSTEM	ROLLBACK	3	2025-03-28 03:37:57.8149	\N	\N
95	counteragent	UPDATE	1	2025-03-28 03:38:07.68885	{"address": "ул. Бизнеса, 1, Город A", "phone_number": 1234567890, "contact_person": "Иван Иванов", "counteragent_id": 1, "counteragent_name": "ООО \\"АвтоЗапчасти\\""}	{"address": "ул. Бизнеса, 1, Город A", "phone_number": 1234567890, "contact_person": "Иван Ивано", "counteragent_id": 1, "counteragent_name": "ООО \\"АвтоЗапчасти\\""}
96	counteragent	UPDATE	1	2025-03-28 03:38:15.382644	{"address": "ул. Бизнеса, 1, Город A", "phone_number": 1234567890, "contact_person": "Иван Ивано", "counteragent_id": 1, "counteragent_name": "ООО \\"АвтоЗапчасти\\""}	{"address": "ул. Бизнеса, 1, Город A", "phone_number": 1234567890, "contact_person": "Иван Иванов", "counteragent_id": 1, "counteragent_name": "ООО \\"АвтоЗапчасти\\""}
97	counteragent	UNDO	95	2025-03-28 03:38:15.382644	{"address": "ул. Бизнеса, 1, Город A", "phone_number": 1234567890, "contact_person": "Иван Ивано", "counteragent_id": 1, "counteragent_name": "ООО \\"АвтоЗапчасти\\""}	{"address": "ул. Бизнеса, 1, Город A", "phone_number": 1234567890, "contact_person": "Иван Иванов", "counteragent_id": 1, "counteragent_name": "ООО \\"АвтоЗапчасти\\""}
98	counteragent	UPDATE	1	2025-03-28 03:38:17.419648	{"address": "ул. Бизнеса, 1, Город A", "phone_number": 1234567890, "contact_person": "Иван Иванов", "counteragent_id": 1, "counteragent_name": "ООО \\"АвтоЗапчасти\\""}	{"address": "ул. Бизнеса, 1, Город A", "phone_number": 1234567890, "contact_person": "Иван Иван", "counteragent_id": 1, "counteragent_name": "ООО \\"АвтоЗапчасти\\""}
99	counteragent	UPDATE	1	2025-03-28 03:38:24.170329	{"address": "ул. Бизнеса, 1, Город A", "phone_number": 1234567890, "contact_person": "Иван Иван", "counteragent_id": 1, "counteragent_name": "ООО \\"АвтоЗапчасти\\""}	{"address": "ул. Бизнеса, 1, Город A", "phone_number": 1234567890, "contact_person": "Иван Иванов", "counteragent_id": 1, "counteragent_name": "ООО \\"АвтоЗапчасти\\""}
100	counteragent	UPDATE	1	2025-03-28 03:38:24.170329	{"address": "ул. Бизнеса, 1, Город A", "phone_number": 1234567890, "contact_person": "Иван Иванов", "counteragent_id": 1, "counteragent_name": "ООО \\"АвтоЗапчасти\\""}	{"address": "ул. Бизнеса, 1, Город A", "phone_number": 1234567890, "contact_person": "Иван Ивано", "counteragent_id": 1, "counteragent_name": "ООО \\"АвтоЗапчасти\\""}
101	counteragent	UPDATE	1	2025-03-28 03:38:24.170329	{"address": "ул. Бизнеса, 1, Город A", "phone_number": 1234567890, "contact_person": "Иван Ивано", "counteragent_id": 1, "counteragent_name": "ООО \\"АвтоЗапчасти\\""}	{"address": "ул. Бизнеса, 1, Город A", "phone_number": 1234567890, "contact_person": "Иван Иванов", "counteragent_id": 1, "counteragent_name": "ООО \\"АвтоЗапчасти\\""}
102	SYSTEM	ROLLBACK	4	2025-03-28 03:38:24.170329	\N	\N
103	invoice	UPDATE	1	2025-03-29 18:19:57.916123	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
104	invoice	UPDATE	1	2025-03-29 18:19:57.975114	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
105	invoice	UNDO	103	2025-03-29 18:19:57.975114	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
106	invoice	UPDATE	1	2025-03-29 18:20:00.184745	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
107	invoice	UNDO	104	2025-03-29 18:20:00.184745	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
108	invoice	UPDATE	1	2025-03-29 18:20:04.28316	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
109	invoice	UPDATE	1	2025-03-29 18:20:04.28316	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
110	invoice	UPDATE	1	2025-03-29 18:20:04.28316	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
111	SYSTEM	ROLLBACK	5	2025-03-29 18:20:04.28316	\N	\N
112	invoice	UPDATE	1	2025-03-29 18:20:35.876246	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
113	invoice	UNDO	110	2025-03-29 18:20:35.876246	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
114	invoice	UPDATE	1	2025-03-29 18:20:39.038488	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
115	invoice	UNDO	112	2025-03-29 18:20:39.038488	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
116	invoice	UPDATE	1	2025-03-29 18:20:43.209262	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
117	invoice	UNDO	114	2025-03-29 18:20:43.209262	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
118	invoice	UPDATE	1	2025-03-29 18:24:32.986942	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
119	invoice	UNDO	116	2025-03-29 18:24:32.986942	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
120	invoice	UPDATE	1	2025-03-29 18:24:34.763445	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
121	invoice	UNDO	118	2025-03-29 18:24:34.763445	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
122	invoice	UPDATE	1	2025-03-29 18:25:29.624279	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
123	invoice	UNDO	120	2025-03-29 18:25:29.624279	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
124	invoice	UPDATE	1	2025-03-29 18:25:32.508584	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
125	invoice	UNDO	122	2025-03-29 18:25:32.508584	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
126	invoice	UPDATE	1	2025-03-29 18:29:38.881403	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
127	invoice	UPDATE	1	2025-03-29 18:29:50.837822	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
128	invoice	UNDO	126	2025-03-29 18:29:50.837822	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
129	invoice	UPDATE	1	2025-03-29 18:29:53.127618	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
130	invoice	UNDO	127	2025-03-29 18:29:53.127618	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
131	invoice	UPDATE	1	2025-03-29 18:32:04.088461	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
132	invoice	UPDATE	1	2025-03-29 18:32:11.905019	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
133	invoice	UNDO	131	2025-03-29 18:32:11.905019	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
134	invoice	UPDATE	1	2025-03-29 18:32:14.110669	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
135	invoice	UNDO	132	2025-03-29 18:32:14.110669	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
136	invoice	UPDATE	1	2025-03-29 18:32:17.227658	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
137	invoice	UNDO	134	2025-03-29 18:32:17.227658	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
138	invoice	UPDATE	1	2025-03-29 18:32:19.849698	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
139	invoice	UNDO	136	2025-03-29 18:32:19.849698	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
140	invoice	UPDATE	1	2025-03-29 18:34:31.226703	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
141	invoice	UPDATE	1	2025-03-29 18:34:39.237531	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
142	invoice	UNDO	140	2025-03-29 18:34:39.237531	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
143	invoice	UPDATE	1	2025-03-29 18:34:41.394467	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
144	invoice	UNDO	141	2025-03-29 18:34:41.394467	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
145	invoice	UPDATE	1	2025-03-29 18:34:54.213538	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
146	invoice	UPDATE	1	2025-03-29 18:35:02.290024	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
147	SYSTEM	ROLLBACK	1	2025-03-29 18:35:02.290024	\N	\N
148	invoice	UPDATE	1	2025-03-29 18:35:05.698022	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
149	invoice	UPDATE	1	2025-03-29 18:35:15.140733	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
150	SYSTEM	ROLLBACK	1	2025-03-29 18:35:15.140733	\N	\N
151	invoice	INSERT	10	2025-03-29 18:35:31.099593	\N	{"status": true, "date_time": "2025-03-29T18:35:00", "invoice_id": 10, "type_invoice": true, "counteragentid": 3}
152	invoice_detail	INSERT	10	2025-03-29 18:35:31.099593	\N	{"detailid": 39, "quantity": 1, "invoiceid": 10}
153	invoice_employee	INSERT	10	2025-03-29 18:35:31.099593	\N	{"invoiceid": 10, "responsible": 2, "when_granted": "2025-03-29T18:35:31.099593", "granted_access": 2}
154	invoice	UPDATE	10	2025-03-29 18:36:27.761857	{"status": true, "date_time": "2025-03-29T18:35:00", "invoice_id": 10, "type_invoice": true, "counteragentid": 3}	{"status": true, "date_time": "2025-03-29T18:35:00", "invoice_id": 10, "type_invoice": true, "counteragentid": 3}
155	invoice_detail	UPDATE	10	2025-03-29 18:36:27.761857	{"detailid": 39, "quantity": 1, "invoiceid": 10}	{"detailid": 5, "quantity": 1, "invoiceid": 10}
156	invoice_employee	UPDATE	10	2025-03-29 18:36:27.761857	{"invoiceid": 10, "responsible": 2, "when_granted": "2025-03-29T18:35:31.099593", "granted_access": 2}	{"invoiceid": 10, "responsible": 3, "when_granted": "2025-03-29T18:35:31.099593", "granted_access": 2}
158	SYSTEM	ROLLBACK	6	2025-03-29 18:37:02.018678	\N	\N
159	invoice	UPDATE	10	2025-03-29 18:40:35.55442	{"status": true, "date_time": "2025-03-29T18:35:00", "invoice_id": 10, "type_invoice": true, "counteragentid": 3}	{"status": false, "date_time": "2025-03-29T18:35:00", "invoice_id": 10, "type_invoice": true, "counteragentid": 3}
160	invoice_detail	UPDATE	10	2025-03-29 18:40:35.55442	{"detailid": 5, "quantity": 1, "invoiceid": 10}	{"detailid": 5, "quantity": 1, "invoiceid": 10}
161	invoice_employee	UPDATE	10	2025-03-29 18:40:35.55442	{"invoiceid": 10, "responsible": 3, "when_granted": "2025-03-29T18:35:31.099593", "granted_access": 2}	{"invoiceid": 10, "responsible": 3, "when_granted": "2025-03-29T18:35:31.099593", "granted_access": 2}
163	SYSTEM	ROLLBACK	3	2025-03-29 18:40:55.8234	\N	\N
164	invoice	UPDATE	10	2025-03-29 18:40:55.825509	{"status": false, "date_time": "2025-03-29T18:35:00", "invoice_id": 10, "type_invoice": true, "counteragentid": 3}	{"status": true, "date_time": "2025-03-29T18:35:00", "invoice_id": 10, "type_invoice": true, "counteragentid": 3}
165	invoice_detail	UPDATE	10	2025-03-29 18:40:55.825509	{"detailid": 5, "quantity": 1, "invoiceid": 10}	{"detailid": 5, "quantity": 1, "invoiceid": 10}
166	invoice_employee	UPDATE	10	2025-03-29 18:40:55.825509	{"invoiceid": 10, "responsible": 3, "when_granted": "2025-03-29T18:35:31.099593", "granted_access": 2}	{"invoiceid": 10, "responsible": 3, "when_granted": "2025-03-29T18:35:31.099593", "granted_access": 2}
168	SYSTEM	ROLLBACK	3	2025-03-29 18:41:04.385068	\N	\N
169	invoice	UPDATE	10	2025-03-29 18:42:01.176311	{"status": true, "date_time": "2025-03-29T18:35:00", "invoice_id": 10, "type_invoice": true, "counteragentid": 3}	{"status": false, "date_time": "2025-03-29T18:35:00", "invoice_id": 10, "type_invoice": true, "counteragentid": 3}
170	invoice_detail	UPDATE	10	2025-03-29 18:42:01.176311	{"detailid": 5, "quantity": 1, "invoiceid": 10}	{"detailid": 5, "quantity": 1, "invoiceid": 10}
171	invoice_employee	UPDATE	10	2025-03-29 18:42:01.176311	{"invoiceid": 10, "responsible": 3, "when_granted": "2025-03-29T18:35:31.099593", "granted_access": 2}	{"invoiceid": 10, "responsible": 3, "when_granted": "2025-03-29T18:35:31.099593", "granted_access": 2}
172	invoice_employee	UPDATE	10	2025-03-29 18:42:06.214406	{"invoiceid": 10, "responsible": 3, "when_granted": "2025-03-29T18:35:31.099593", "granted_access": 2}	{"invoiceid": 10, "responsible": 3, "when_granted": "2025-03-29T18:35:31.099593", "granted_access": 2}
173	invoice_employee	UNDO	171	2025-03-29 18:42:06.214406	{"invoiceid": 10, "responsible": 3, "when_granted": "2025-03-29T18:35:31.099593", "granted_access": 2}	{"invoiceid": 10, "responsible": 3, "when_granted": "2025-03-29T18:35:31.099593", "granted_access": 2}
174	invoice_detail	DELETE	10	2025-03-29 18:42:08.178665	{"detailid": 5, "quantity": 1, "invoiceid": 10}	\N
175	invoice_employee	DELETE	10	2025-03-29 18:42:08.178665	{"invoiceid": 10, "responsible": 3, "when_granted": "2025-03-29T18:35:31.099593", "granted_access": 2}	\N
176	invoice	DELETE	10	2025-03-29 18:42:08.178665	{"status": false, "date_time": "2025-03-29T18:35:00", "invoice_id": 10, "type_invoice": true, "counteragentid": 3}	\N
177	invoice	INSERT	10	2025-03-29 18:42:13.307876	\N	{"status": false, "date_time": "2025-03-29T18:35:00", "invoice_id": 10, "type_invoice": true, "counteragentid": 3}
178	invoice	UNDO	176	2025-03-29 18:42:13.307876	\N	{"status": false, "date_time": "2025-03-29T18:35:00", "invoice_id": 10, "type_invoice": true, "counteragentid": 3}
179	invoice	DELETE	10	2025-03-29 18:42:15.326599	{"status": false, "date_time": "2025-03-29T18:35:00", "invoice_id": 10, "type_invoice": true, "counteragentid": 3}	\N
180	invoice	UNDO	177	2025-03-29 18:42:15.326599	{"status": false, "date_time": "2025-03-29T18:35:00", "invoice_id": 10, "type_invoice": true, "counteragentid": 3}	\N
181	invoice	INSERT	10	2025-03-29 18:42:27.533189	\N	{"status": false, "date_time": "2025-03-29T18:35:00", "invoice_id": 10, "type_invoice": true, "counteragentid": 3}
182	invoice	DELETE	10	2025-03-29 18:42:27.533189	{"status": false, "date_time": "2025-03-29T18:35:00", "invoice_id": 10, "type_invoice": true, "counteragentid": 3}	\N
183	invoice	INSERT	10	2025-03-29 18:42:27.533189	\N	{"status": false, "date_time": "2025-03-29T18:35:00", "invoice_id": 10, "type_invoice": true, "counteragentid": 3}
184	SYSTEM	ROLLBACK	12	2025-03-29 18:42:27.533189	\N	\N
185	invoice	INSERT	11	2025-03-29 18:46:57.383684	\N	{"status": false, "date_time": "2025-03-29T18:47:00", "invoice_id": 11, "type_invoice": true, "counteragentid": 3}
186	invoice_detail	INSERT	11	2025-03-29 18:46:57.383684	\N	{"detailid": 5, "quantity": 1, "invoiceid": 11}
187	invoice_employee	INSERT	11	2025-03-29 18:46:57.383684	\N	{"invoiceid": 11, "responsible": 2, "when_granted": "2025-03-29T18:46:57.383684", "granted_access": 2}
188	invoice_detail	DELETE	11	2025-03-29 18:47:26.005217	{"detailid": 5, "quantity": 1, "invoiceid": 11}	\N
189	invoice_detail	UNDO	186	2025-03-29 18:47:26.005217	{"detailid": 5, "quantity": 1, "invoiceid": 11}	\N
190	invoice_detail	INSERT	11	2025-03-29 18:47:28.61465	\N	{"detailid": 5, "quantity": 1, "invoiceid": 11}
191	invoice_detail	DELETE	11	2025-03-29 18:47:28.61465	{"detailid": 5, "quantity": 1, "invoiceid": 11}	\N
192	invoice_employee	DELETE	11	2025-03-29 18:47:28.61465	{"invoiceid": 11, "responsible": 2, "when_granted": "2025-03-29T18:46:57.383684", "granted_access": 2}	\N
193	invoice	DELETE	11	2025-03-29 18:47:28.61465	{"status": false, "date_time": "2025-03-29T18:47:00", "invoice_id": 11, "type_invoice": true, "counteragentid": 3}	\N
194	SYSTEM	ROLLBACK	5	2025-03-29 18:47:28.61465	\N	\N
260	rack	UPDATE	3	2025-03-29 22:00:01.003071	{"roomid": 1, "rack_id": 3, "rack_number": 30}	{"roomid": 1, "rack_id": 3, "rack_number": 140}
195	invoice	UPDATE	9	2025-03-29 18:47:35.389403	{"status": false, "date_time": "2025-03-28T02:00:00", "invoice_id": 9, "type_invoice": false, "counteragentid": 2}	{"status": false, "date_time": "2025-03-28T02:00:00", "invoice_id": 9, "type_invoice": false, "counteragentid": 2}
196	invoice_detail	UPDATE	9	2025-03-29 18:47:35.389403	{"detailid": 4, "quantity": 10, "invoiceid": 9}	{"detailid": 5, "quantity": 10, "invoiceid": 9}
197	invoice_employee	UPDATE	9	2025-03-29 18:47:35.389403	{"invoiceid": 9, "responsible": 2, "when_granted": "2025-03-28T02:00:43.000485", "granted_access": 2}	{"invoiceid": 9, "responsible": 2, "when_granted": "2025-03-28T02:00:43.000485", "granted_access": 2}
198	invoice_detail	UPDATE	9	2025-03-29 18:47:43.475696	{"detailid": 5, "quantity": 10, "invoiceid": 9}	{"detailid": 4, "quantity": 10, "invoiceid": 9}
199	invoice_employee	UPDATE	9	2025-03-29 18:47:43.475696	{"invoiceid": 9, "responsible": 2, "when_granted": "2025-03-28T02:00:43.000485", "granted_access": 2}	{"invoiceid": 9, "responsible": 2, "when_granted": "2025-03-28T02:00:43.000485", "granted_access": 2}
200	invoice	UPDATE	9	2025-03-29 18:47:43.475696	{"status": false, "date_time": "2025-03-28T02:00:00", "invoice_id": 9, "type_invoice": false, "counteragentid": 2}	{"status": false, "date_time": "2025-03-28T02:00:00", "invoice_id": 9, "type_invoice": false, "counteragentid": 2}
201	SYSTEM	ROLLBACK	3	2025-03-29 18:47:43.475696	\N	\N
202	invoice	UPDATE	1	2025-03-29 18:49:02.413365	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
203	invoice	UPDATE	1	2025-03-29 18:49:22.985273	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
204	SYSTEM	ROLLBACK	1	2025-03-29 18:49:22.985273	\N	\N
205	invoice	UPDATE	1	2025-03-29 18:49:25.455657	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
206	invoice	UPDATE	1	2025-03-29 18:49:31.713849	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
207	invoice	UNDO	205	2025-03-29 18:49:31.713849	{"status": true, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
208	warehouse	INSERT	7	2025-03-29 19:22:55.104301	\N	{"address": "ул. Краснаяб, 123, Батайск", "warehouse_id": 7, "warehouse_number": 105}
209	warehouse	INSERT	8	2025-03-29 19:23:43.702832	\N	{"address": "ул. Краснаяб, 124, Батайск", "warehouse_id": 8, "warehouse_number": 105}
210	warehouse	UPDATE	8	2025-03-29 19:24:09.453308	{"address": "ул. Краснаяб, 124, Батайск", "warehouse_id": 8, "warehouse_number": 105}	{"address": "ул. Краснаяб, 124, Батайск", "warehouse_id": 8, "warehouse_number": 106}
211	warehouse	DELETE	7	2025-03-29 19:33:08.16527	{"address": "ул. Краснаяб, 123, Батайск", "warehouse_id": 7, "warehouse_number": 105}	\N
212	room	INSERT	26	2025-03-29 19:33:16.389724	\N	{"room_id": 26, "room_number": 1, "warehouseid": 8}
213	room	UPDATE	1	2025-03-29 19:33:29.372095	{"room_id": 1, "room_number": 1, "warehouseid": 1}	{"room_id": 1, "room_number": 11, "warehouseid": 1}
214	room	UPDATE	2	2025-03-29 19:33:41.594968	{"room_id": 2, "room_number": 2, "warehouseid": 1}	{"room_id": 2, "room_number": 12, "warehouseid": 1}
215	room	UPDATE	3	2025-03-29 19:39:28.893469	{"room_id": 3, "room_number": 3, "warehouseid": 1}	{"room_id": 3, "room_number": 13, "warehouseid": 1}
216	warehouse	UPDATE	8	2025-03-29 19:49:09.514702	{"address": "ул. Краснаяб, 124, Батайск", "warehouse_id": 8, "warehouse_number": 106}	{"address": "ул. Краснаяб, 124, Батайск", "warehouse_id": 8, "warehouse_number": 106}
217	warehouse	INSERT	9	2025-03-29 19:49:45.323303	\N	{"address": "ул. Вязовая, 1215, Город E", "warehouse_id": 9, "warehouse_number": 107}
218	warehouse	UPDATE	9	2025-03-29 19:50:24.35374	{"address": "ул. Вязовая, 1215, Город E", "warehouse_id": 9, "warehouse_number": 107}	{"address": "ул. Вязовая, 1415, Город E", "warehouse_id": 9, "warehouse_number": 107}
219	warehouse	DELETE	9	2025-03-29 19:53:42.11829	{"address": "ул. Вязовая, 1415, Город E", "warehouse_id": 9, "warehouse_number": 107}	\N
220	warehouse	UPDATE	8	2025-03-29 19:53:46.258067	{"address": "ул. Краснаяб, 124, Батайск", "warehouse_id": 8, "warehouse_number": 106}	{"address": "ул. Красная, 124, Батайск", "warehouse_id": 8, "warehouse_number": 106}
221	room	UPDATE	4	2025-03-29 20:30:31.493386	{"room_id": 4, "room_number": 4, "warehouseid": 1}	{"room_id": 4, "room_number": 14, "warehouseid": 1}
222	room	UPDATE	5	2025-03-29 20:38:51.05254	{"room_id": 5, "room_number": 5, "warehouseid": 1}	{"room_id": 5, "room_number": 15, "warehouseid": 1}
223	details	UPDATE	6	2025-03-29 20:50:36.235874	{"weight": 12.5, "shelfid": 6, "detail_id": 6, "type_detail": "Двигатель"}	{"weight": 12, "shelfid": 6, "detail_id": 6, "type_detail": "Двигатель"}
224	details	UPDATE	6	2025-03-29 20:54:03.483206	{"weight": 12, "shelfid": 6, "detail_id": 6, "type_detail": "Двигатель"}	{"weight": 12.2, "shelfid": 6, "detail_id": 6, "type_detail": "Двигатель"}
225	details	UPDATE	6	2025-03-29 20:59:35.463714	{"weight": 12.2, "shelfid": 6, "detail_id": 6, "type_detail": "Двигатель"}	{"weight": 12.1, "shelfid": 6, "detail_id": 6, "type_detail": "Двигатель"}
226	details	UPDATE	6	2025-03-29 21:02:13.399029	{"weight": 12.1, "shelfid": 6, "detail_id": 6, "type_detail": "Двигатель"}	{"weight": 12.1, "shelfid": 11, "detail_id": 6, "type_detail": "Двигатель"}
227	details	UPDATE	6	2025-03-29 21:03:47.734246	{"weight": 12.1, "shelfid": 11, "detail_id": 6, "type_detail": "Двигатель"}	{"weight": 12.3, "shelfid": 11, "detail_id": 6, "type_detail": "Двигатель"}
228	details	UPDATE	6	2025-03-29 21:06:35.412188	{"weight": 12.3, "shelfid": 11, "detail_id": 6, "type_detail": "Двигатель"}	{"weight": 12.4, "shelfid": 11, "detail_id": 6, "type_detail": "Двигатель"}
229	room	UPDATE	6	2025-03-29 21:08:21.531908	{"room_id": 6, "room_number": 1, "warehouseid": 2}	{"room_id": 6, "room_number": 21, "warehouseid": 2}
230	room	UPDATE	7	2025-03-29 21:14:10.595694	{"room_id": 7, "room_number": 2, "warehouseid": 2}	{"room_id": 7, "room_number": 22, "warehouseid": 2}
231	room	UPDATE	8	2025-03-29 21:17:34.394065	{"room_id": 8, "room_number": 3, "warehouseid": 2}	{"room_id": 8, "room_number": 23, "warehouseid": 2}
232	room	UPDATE	9	2025-03-29 21:17:49.96217	{"room_id": 9, "room_number": 4, "warehouseid": 2}	{"room_id": 9, "room_number": 24, "warehouseid": 2}
233	room	UPDATE	10	2025-03-29 21:18:08.229868	{"room_id": 10, "room_number": 5, "warehouseid": 2}	{"room_id": 10, "room_number": 25, "warehouseid": 2}
1760	invoice	INSERT	12	2025-03-29 22:13:00.411972	\N	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1761	invoice_detail	INSERT	12	2025-03-29 22:13:00.411972	\N	{"detailid": 20, "quantity": 1, "invoiceid": 12}
1762	invoice_employee	INSERT	12	2025-03-29 22:13:00.411972	\N	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1763	invoice	UPDATE	12	2025-03-29 22:13:25.074327	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1764	invoice_detail	UPDATE	12	2025-03-29 22:13:25.074327	{"detailid": 20, "quantity": 1, "invoiceid": 12}	{"detailid": 20, "quantity": 2, "invoiceid": 12}
239	room	UPDATE	11	2025-03-29 21:41:44.441469	{"room_id": 11, "room_number": 1, "warehouseid": 3}	{"room_id": 11, "room_number": 31, "warehouseid": 3}
240	room	UPDATE	12	2025-03-29 21:44:46.154031	{"room_id": 12, "room_number": 2, "warehouseid": 3}	{"room_id": 12, "room_number": 32, "warehouseid": 3}
241	room	UPDATE	13	2025-03-29 21:45:02.618593	{"room_id": 13, "room_number": 3, "warehouseid": 3}	{"room_id": 13, "room_number": 33, "warehouseid": 3}
242	room	UPDATE	14	2025-03-29 21:51:50.532055	{"room_id": 14, "room_number": 4, "warehouseid": 3}	{"room_id": 14, "room_number": 34, "warehouseid": 3}
243	room	UPDATE	15	2025-03-29 21:52:04.991518	{"room_id": 15, "room_number": 5, "warehouseid": 3}	{"room_id": 15, "room_number": 35, "warehouseid": 3}
244	room	UPDATE	16	2025-03-29 21:52:12.149593	{"room_id": 16, "room_number": 1, "warehouseid": 4}	{"room_id": 16, "room_number": 41, "warehouseid": 4}
245	room	UPDATE	17	2025-03-29 21:52:24.836667	{"room_id": 17, "room_number": 2, "warehouseid": 4}	{"room_id": 17, "room_number": 42, "warehouseid": 4}
246	room	UPDATE	18	2025-03-29 21:52:30.623684	{"room_id": 18, "room_number": 3, "warehouseid": 4}	{"room_id": 18, "room_number": 43, "warehouseid": 4}
247	room	UPDATE	19	2025-03-29 21:52:35.447219	{"room_id": 19, "room_number": 4, "warehouseid": 4}	{"room_id": 19, "room_number": 44, "warehouseid": 4}
248	room	UPDATE	20	2025-03-29 21:52:39.074293	{"room_id": 20, "room_number": 5, "warehouseid": 4}	{"room_id": 20, "room_number": 45, "warehouseid": 4}
249	room	UPDATE	11	2025-03-29 21:52:45.286708	{"room_id": 11, "room_number": 31, "warehouseid": 3}	{"room_id": 11, "room_number": 31, "warehouseid": 5}
250	room	UPDATE	11	2025-03-29 21:53:01.850477	{"room_id": 11, "room_number": 31, "warehouseid": 5}	{"room_id": 11, "room_number": 31, "warehouseid": 3}
251	room	UPDATE	21	2025-03-29 21:53:09.733611	{"room_id": 21, "room_number": 1, "warehouseid": 5}	{"room_id": 21, "room_number": 51, "warehouseid": 5}
252	room	UPDATE	22	2025-03-29 21:53:23.128068	{"room_id": 22, "room_number": 2, "warehouseid": 5}	{"room_id": 22, "room_number": 52, "warehouseid": 5}
253	room	UPDATE	23	2025-03-29 21:53:28.067012	{"room_id": 23, "room_number": 3, "warehouseid": 5}	{"room_id": 23, "room_number": 53, "warehouseid": 5}
254	room	UPDATE	24	2025-03-29 21:53:32.494704	{"room_id": 24, "room_number": 4, "warehouseid": 5}	{"room_id": 24, "room_number": 54, "warehouseid": 5}
255	room	UPDATE	25	2025-03-29 21:53:39.225056	{"room_id": 25, "room_number": 5, "warehouseid": 5}	{"room_id": 25, "room_number": 55, "warehouseid": 5}
256	room	UPDATE	26	2025-03-29 21:53:42.910127	{"room_id": 26, "room_number": 1, "warehouseid": 8}	{"room_id": 26, "room_number": 61, "warehouseid": 8}
257	rack	INSERT	126	2025-03-29 21:54:20.040219	\N	{"roomid": 26, "rack_id": 126, "rack_number": 10}
258	rack	UPDATE	1	2025-03-29 22:00:01.003071	{"roomid": 1, "rack_id": 1, "rack_number": 10}	{"roomid": 1, "rack_id": 1, "rack_number": 120}
259	rack	UPDATE	2	2025-03-29 22:00:01.003071	{"roomid": 1, "rack_id": 2, "rack_number": 20}	{"roomid": 1, "rack_id": 2, "rack_number": 130}
261	rack	UPDATE	4	2025-03-29 22:00:01.003071	{"roomid": 1, "rack_id": 4, "rack_number": 40}	{"roomid": 1, "rack_id": 4, "rack_number": 150}
262	rack	UPDATE	5	2025-03-29 22:00:01.003071	{"roomid": 1, "rack_id": 5, "rack_number": 50}	{"roomid": 1, "rack_id": 5, "rack_number": 160}
263	rack	UPDATE	6	2025-03-29 22:00:01.003071	{"roomid": 2, "rack_id": 6, "rack_number": 10}	{"roomid": 2, "rack_id": 6, "rack_number": 130}
264	rack	UPDATE	7	2025-03-29 22:00:01.003071	{"roomid": 2, "rack_id": 7, "rack_number": 20}	{"roomid": 2, "rack_id": 7, "rack_number": 140}
265	rack	UPDATE	8	2025-03-29 22:00:01.003071	{"roomid": 2, "rack_id": 8, "rack_number": 30}	{"roomid": 2, "rack_id": 8, "rack_number": 150}
266	rack	UPDATE	9	2025-03-29 22:00:01.003071	{"roomid": 2, "rack_id": 9, "rack_number": 40}	{"roomid": 2, "rack_id": 9, "rack_number": 160}
267	rack	UPDATE	10	2025-03-29 22:00:01.003071	{"roomid": 2, "rack_id": 10, "rack_number": 50}	{"roomid": 2, "rack_id": 10, "rack_number": 170}
268	rack	UPDATE	11	2025-03-29 22:00:01.003071	{"roomid": 3, "rack_id": 11, "rack_number": 10}	{"roomid": 3, "rack_id": 11, "rack_number": 140}
269	rack	UPDATE	12	2025-03-29 22:00:01.003071	{"roomid": 3, "rack_id": 12, "rack_number": 20}	{"roomid": 3, "rack_id": 12, "rack_number": 150}
270	rack	UPDATE	13	2025-03-29 22:00:01.003071	{"roomid": 3, "rack_id": 13, "rack_number": 30}	{"roomid": 3, "rack_id": 13, "rack_number": 160}
271	rack	UPDATE	14	2025-03-29 22:00:01.003071	{"roomid": 3, "rack_id": 14, "rack_number": 40}	{"roomid": 3, "rack_id": 14, "rack_number": 170}
272	rack	UPDATE	15	2025-03-29 22:00:01.003071	{"roomid": 3, "rack_id": 15, "rack_number": 50}	{"roomid": 3, "rack_id": 15, "rack_number": 180}
273	rack	UPDATE	16	2025-03-29 22:00:01.003071	{"roomid": 4, "rack_id": 16, "rack_number": 10}	{"roomid": 4, "rack_id": 16, "rack_number": 150}
274	rack	UPDATE	17	2025-03-29 22:00:01.003071	{"roomid": 4, "rack_id": 17, "rack_number": 20}	{"roomid": 4, "rack_id": 17, "rack_number": 160}
275	rack	UPDATE	18	2025-03-29 22:00:01.003071	{"roomid": 4, "rack_id": 18, "rack_number": 30}	{"roomid": 4, "rack_id": 18, "rack_number": 170}
276	rack	UPDATE	19	2025-03-29 22:00:01.003071	{"roomid": 4, "rack_id": 19, "rack_number": 40}	{"roomid": 4, "rack_id": 19, "rack_number": 180}
277	rack	UPDATE	20	2025-03-29 22:00:01.003071	{"roomid": 4, "rack_id": 20, "rack_number": 50}	{"roomid": 4, "rack_id": 20, "rack_number": 190}
278	rack	UPDATE	21	2025-03-29 22:00:01.003071	{"roomid": 5, "rack_id": 21, "rack_number": 10}	{"roomid": 5, "rack_id": 21, "rack_number": 160}
279	rack	UPDATE	22	2025-03-29 22:00:01.003071	{"roomid": 5, "rack_id": 22, "rack_number": 20}	{"roomid": 5, "rack_id": 22, "rack_number": 170}
280	rack	UPDATE	23	2025-03-29 22:00:01.003071	{"roomid": 5, "rack_id": 23, "rack_number": 30}	{"roomid": 5, "rack_id": 23, "rack_number": 180}
281	rack	UPDATE	24	2025-03-29 22:00:01.003071	{"roomid": 5, "rack_id": 24, "rack_number": 40}	{"roomid": 5, "rack_id": 24, "rack_number": 190}
282	rack	UPDATE	25	2025-03-29 22:00:01.003071	{"roomid": 5, "rack_id": 25, "rack_number": 50}	{"roomid": 5, "rack_id": 25, "rack_number": 200}
283	rack	UPDATE	26	2025-03-29 22:00:01.003071	{"roomid": 6, "rack_id": 26, "rack_number": 10}	{"roomid": 6, "rack_id": 26, "rack_number": 220}
284	rack	UPDATE	27	2025-03-29 22:00:01.003071	{"roomid": 6, "rack_id": 27, "rack_number": 20}	{"roomid": 6, "rack_id": 27, "rack_number": 230}
285	rack	UPDATE	28	2025-03-29 22:00:01.003071	{"roomid": 6, "rack_id": 28, "rack_number": 30}	{"roomid": 6, "rack_id": 28, "rack_number": 240}
286	rack	UPDATE	29	2025-03-29 22:00:01.003071	{"roomid": 6, "rack_id": 29, "rack_number": 40}	{"roomid": 6, "rack_id": 29, "rack_number": 250}
287	rack	UPDATE	30	2025-03-29 22:00:01.003071	{"roomid": 6, "rack_id": 30, "rack_number": 50}	{"roomid": 6, "rack_id": 30, "rack_number": 260}
288	rack	UPDATE	31	2025-03-29 22:00:01.003071	{"roomid": 7, "rack_id": 31, "rack_number": 10}	{"roomid": 7, "rack_id": 31, "rack_number": 230}
289	rack	UPDATE	32	2025-03-29 22:00:01.003071	{"roomid": 7, "rack_id": 32, "rack_number": 20}	{"roomid": 7, "rack_id": 32, "rack_number": 240}
290	rack	UPDATE	33	2025-03-29 22:00:01.003071	{"roomid": 7, "rack_id": 33, "rack_number": 30}	{"roomid": 7, "rack_id": 33, "rack_number": 250}
291	rack	UPDATE	34	2025-03-29 22:00:01.003071	{"roomid": 7, "rack_id": 34, "rack_number": 40}	{"roomid": 7, "rack_id": 34, "rack_number": 260}
292	rack	UPDATE	35	2025-03-29 22:00:01.003071	{"roomid": 7, "rack_id": 35, "rack_number": 50}	{"roomid": 7, "rack_id": 35, "rack_number": 270}
293	rack	UPDATE	36	2025-03-29 22:00:01.003071	{"roomid": 8, "rack_id": 36, "rack_number": 10}	{"roomid": 8, "rack_id": 36, "rack_number": 240}
294	rack	UPDATE	37	2025-03-29 22:00:01.003071	{"roomid": 8, "rack_id": 37, "rack_number": 20}	{"roomid": 8, "rack_id": 37, "rack_number": 250}
295	rack	UPDATE	38	2025-03-29 22:00:01.003071	{"roomid": 8, "rack_id": 38, "rack_number": 30}	{"roomid": 8, "rack_id": 38, "rack_number": 260}
296	rack	UPDATE	39	2025-03-29 22:00:01.003071	{"roomid": 8, "rack_id": 39, "rack_number": 40}	{"roomid": 8, "rack_id": 39, "rack_number": 270}
297	rack	UPDATE	40	2025-03-29 22:00:01.003071	{"roomid": 8, "rack_id": 40, "rack_number": 50}	{"roomid": 8, "rack_id": 40, "rack_number": 280}
298	rack	UPDATE	41	2025-03-29 22:00:01.003071	{"roomid": 9, "rack_id": 41, "rack_number": 10}	{"roomid": 9, "rack_id": 41, "rack_number": 250}
299	rack	UPDATE	42	2025-03-29 22:00:01.003071	{"roomid": 9, "rack_id": 42, "rack_number": 20}	{"roomid": 9, "rack_id": 42, "rack_number": 260}
300	rack	UPDATE	43	2025-03-29 22:00:01.003071	{"roomid": 9, "rack_id": 43, "rack_number": 30}	{"roomid": 9, "rack_id": 43, "rack_number": 270}
301	rack	UPDATE	44	2025-03-29 22:00:01.003071	{"roomid": 9, "rack_id": 44, "rack_number": 40}	{"roomid": 9, "rack_id": 44, "rack_number": 280}
302	rack	UPDATE	45	2025-03-29 22:00:01.003071	{"roomid": 9, "rack_id": 45, "rack_number": 50}	{"roomid": 9, "rack_id": 45, "rack_number": 290}
303	rack	UPDATE	46	2025-03-29 22:00:01.003071	{"roomid": 10, "rack_id": 46, "rack_number": 10}	{"roomid": 10, "rack_id": 46, "rack_number": 260}
304	rack	UPDATE	47	2025-03-29 22:00:01.003071	{"roomid": 10, "rack_id": 47, "rack_number": 20}	{"roomid": 10, "rack_id": 47, "rack_number": 270}
305	rack	UPDATE	48	2025-03-29 22:00:01.003071	{"roomid": 10, "rack_id": 48, "rack_number": 30}	{"roomid": 10, "rack_id": 48, "rack_number": 280}
306	rack	UPDATE	49	2025-03-29 22:00:01.003071	{"roomid": 10, "rack_id": 49, "rack_number": 40}	{"roomid": 10, "rack_id": 49, "rack_number": 290}
307	rack	UPDATE	50	2025-03-29 22:00:01.003071	{"roomid": 10, "rack_id": 50, "rack_number": 50}	{"roomid": 10, "rack_id": 50, "rack_number": 300}
308	rack	UPDATE	51	2025-03-29 22:00:01.003071	{"roomid": 11, "rack_id": 51, "rack_number": 10}	{"roomid": 11, "rack_id": 51, "rack_number": 320}
309	rack	UPDATE	52	2025-03-29 22:00:01.003071	{"roomid": 11, "rack_id": 52, "rack_number": 20}	{"roomid": 11, "rack_id": 52, "rack_number": 330}
310	rack	UPDATE	53	2025-03-29 22:00:01.003071	{"roomid": 11, "rack_id": 53, "rack_number": 30}	{"roomid": 11, "rack_id": 53, "rack_number": 340}
311	rack	UPDATE	54	2025-03-29 22:00:01.003071	{"roomid": 11, "rack_id": 54, "rack_number": 40}	{"roomid": 11, "rack_id": 54, "rack_number": 350}
312	rack	UPDATE	55	2025-03-29 22:00:01.003071	{"roomid": 11, "rack_id": 55, "rack_number": 50}	{"roomid": 11, "rack_id": 55, "rack_number": 360}
313	rack	UPDATE	56	2025-03-29 22:00:01.003071	{"roomid": 12, "rack_id": 56, "rack_number": 10}	{"roomid": 12, "rack_id": 56, "rack_number": 330}
314	rack	UPDATE	57	2025-03-29 22:00:01.003071	{"roomid": 12, "rack_id": 57, "rack_number": 20}	{"roomid": 12, "rack_id": 57, "rack_number": 340}
315	rack	UPDATE	58	2025-03-29 22:00:01.003071	{"roomid": 12, "rack_id": 58, "rack_number": 30}	{"roomid": 12, "rack_id": 58, "rack_number": 350}
316	rack	UPDATE	59	2025-03-29 22:00:01.003071	{"roomid": 12, "rack_id": 59, "rack_number": 40}	{"roomid": 12, "rack_id": 59, "rack_number": 360}
317	rack	UPDATE	60	2025-03-29 22:00:01.003071	{"roomid": 12, "rack_id": 60, "rack_number": 50}	{"roomid": 12, "rack_id": 60, "rack_number": 370}
318	rack	UPDATE	61	2025-03-29 22:00:01.003071	{"roomid": 13, "rack_id": 61, "rack_number": 10}	{"roomid": 13, "rack_id": 61, "rack_number": 340}
319	rack	UPDATE	62	2025-03-29 22:00:01.003071	{"roomid": 13, "rack_id": 62, "rack_number": 20}	{"roomid": 13, "rack_id": 62, "rack_number": 350}
320	rack	UPDATE	63	2025-03-29 22:00:01.003071	{"roomid": 13, "rack_id": 63, "rack_number": 30}	{"roomid": 13, "rack_id": 63, "rack_number": 360}
321	rack	UPDATE	64	2025-03-29 22:00:01.003071	{"roomid": 13, "rack_id": 64, "rack_number": 40}	{"roomid": 13, "rack_id": 64, "rack_number": 370}
322	rack	UPDATE	65	2025-03-29 22:00:01.003071	{"roomid": 13, "rack_id": 65, "rack_number": 50}	{"roomid": 13, "rack_id": 65, "rack_number": 380}
323	rack	UPDATE	66	2025-03-29 22:00:01.003071	{"roomid": 14, "rack_id": 66, "rack_number": 10}	{"roomid": 14, "rack_id": 66, "rack_number": 350}
324	rack	UPDATE	67	2025-03-29 22:00:01.003071	{"roomid": 14, "rack_id": 67, "rack_number": 20}	{"roomid": 14, "rack_id": 67, "rack_number": 360}
325	rack	UPDATE	68	2025-03-29 22:00:01.003071	{"roomid": 14, "rack_id": 68, "rack_number": 30}	{"roomid": 14, "rack_id": 68, "rack_number": 370}
326	rack	UPDATE	69	2025-03-29 22:00:01.003071	{"roomid": 14, "rack_id": 69, "rack_number": 40}	{"roomid": 14, "rack_id": 69, "rack_number": 380}
327	rack	UPDATE	70	2025-03-29 22:00:01.003071	{"roomid": 14, "rack_id": 70, "rack_number": 50}	{"roomid": 14, "rack_id": 70, "rack_number": 390}
328	rack	UPDATE	71	2025-03-29 22:00:01.003071	{"roomid": 15, "rack_id": 71, "rack_number": 10}	{"roomid": 15, "rack_id": 71, "rack_number": 360}
329	rack	UPDATE	72	2025-03-29 22:00:01.003071	{"roomid": 15, "rack_id": 72, "rack_number": 20}	{"roomid": 15, "rack_id": 72, "rack_number": 370}
330	rack	UPDATE	73	2025-03-29 22:00:01.003071	{"roomid": 15, "rack_id": 73, "rack_number": 30}	{"roomid": 15, "rack_id": 73, "rack_number": 380}
331	rack	UPDATE	74	2025-03-29 22:00:01.003071	{"roomid": 15, "rack_id": 74, "rack_number": 40}	{"roomid": 15, "rack_id": 74, "rack_number": 390}
332	rack	UPDATE	75	2025-03-29 22:00:01.003071	{"roomid": 15, "rack_id": 75, "rack_number": 50}	{"roomid": 15, "rack_id": 75, "rack_number": 400}
333	rack	UPDATE	76	2025-03-29 22:00:01.003071	{"roomid": 16, "rack_id": 76, "rack_number": 10}	{"roomid": 16, "rack_id": 76, "rack_number": 420}
334	rack	UPDATE	77	2025-03-29 22:00:01.003071	{"roomid": 16, "rack_id": 77, "rack_number": 20}	{"roomid": 16, "rack_id": 77, "rack_number": 430}
335	rack	UPDATE	78	2025-03-29 22:00:01.003071	{"roomid": 16, "rack_id": 78, "rack_number": 30}	{"roomid": 16, "rack_id": 78, "rack_number": 440}
336	rack	UPDATE	79	2025-03-29 22:00:01.003071	{"roomid": 16, "rack_id": 79, "rack_number": 40}	{"roomid": 16, "rack_id": 79, "rack_number": 450}
337	rack	UPDATE	80	2025-03-29 22:00:01.003071	{"roomid": 16, "rack_id": 80, "rack_number": 50}	{"roomid": 16, "rack_id": 80, "rack_number": 460}
338	rack	UPDATE	81	2025-03-29 22:00:01.003071	{"roomid": 17, "rack_id": 81, "rack_number": 10}	{"roomid": 17, "rack_id": 81, "rack_number": 430}
339	rack	UPDATE	82	2025-03-29 22:00:01.003071	{"roomid": 17, "rack_id": 82, "rack_number": 20}	{"roomid": 17, "rack_id": 82, "rack_number": 440}
340	rack	UPDATE	83	2025-03-29 22:00:01.003071	{"roomid": 17, "rack_id": 83, "rack_number": 30}	{"roomid": 17, "rack_id": 83, "rack_number": 450}
341	rack	UPDATE	84	2025-03-29 22:00:01.003071	{"roomid": 17, "rack_id": 84, "rack_number": 40}	{"roomid": 17, "rack_id": 84, "rack_number": 460}
342	rack	UPDATE	85	2025-03-29 22:00:01.003071	{"roomid": 17, "rack_id": 85, "rack_number": 50}	{"roomid": 17, "rack_id": 85, "rack_number": 470}
343	rack	UPDATE	86	2025-03-29 22:00:01.003071	{"roomid": 18, "rack_id": 86, "rack_number": 10}	{"roomid": 18, "rack_id": 86, "rack_number": 440}
344	rack	UPDATE	87	2025-03-29 22:00:01.003071	{"roomid": 18, "rack_id": 87, "rack_number": 20}	{"roomid": 18, "rack_id": 87, "rack_number": 450}
345	rack	UPDATE	88	2025-03-29 22:00:01.003071	{"roomid": 18, "rack_id": 88, "rack_number": 30}	{"roomid": 18, "rack_id": 88, "rack_number": 460}
346	rack	UPDATE	89	2025-03-29 22:00:01.003071	{"roomid": 18, "rack_id": 89, "rack_number": 40}	{"roomid": 18, "rack_id": 89, "rack_number": 470}
347	rack	UPDATE	90	2025-03-29 22:00:01.003071	{"roomid": 18, "rack_id": 90, "rack_number": 50}	{"roomid": 18, "rack_id": 90, "rack_number": 480}
348	rack	UPDATE	91	2025-03-29 22:00:01.003071	{"roomid": 19, "rack_id": 91, "rack_number": 10}	{"roomid": 19, "rack_id": 91, "rack_number": 450}
349	rack	UPDATE	92	2025-03-29 22:00:01.003071	{"roomid": 19, "rack_id": 92, "rack_number": 20}	{"roomid": 19, "rack_id": 92, "rack_number": 460}
350	rack	UPDATE	93	2025-03-29 22:00:01.003071	{"roomid": 19, "rack_id": 93, "rack_number": 30}	{"roomid": 19, "rack_id": 93, "rack_number": 470}
351	rack	UPDATE	94	2025-03-29 22:00:01.003071	{"roomid": 19, "rack_id": 94, "rack_number": 40}	{"roomid": 19, "rack_id": 94, "rack_number": 480}
352	rack	UPDATE	95	2025-03-29 22:00:01.003071	{"roomid": 19, "rack_id": 95, "rack_number": 50}	{"roomid": 19, "rack_id": 95, "rack_number": 490}
353	rack	UPDATE	96	2025-03-29 22:00:01.003071	{"roomid": 20, "rack_id": 96, "rack_number": 10}	{"roomid": 20, "rack_id": 96, "rack_number": 460}
354	rack	UPDATE	97	2025-03-29 22:00:01.003071	{"roomid": 20, "rack_id": 97, "rack_number": 20}	{"roomid": 20, "rack_id": 97, "rack_number": 470}
355	rack	UPDATE	98	2025-03-29 22:00:01.003071	{"roomid": 20, "rack_id": 98, "rack_number": 30}	{"roomid": 20, "rack_id": 98, "rack_number": 480}
356	rack	UPDATE	99	2025-03-29 22:00:01.003071	{"roomid": 20, "rack_id": 99, "rack_number": 40}	{"roomid": 20, "rack_id": 99, "rack_number": 490}
357	rack	UPDATE	100	2025-03-29 22:00:01.003071	{"roomid": 20, "rack_id": 100, "rack_number": 50}	{"roomid": 20, "rack_id": 100, "rack_number": 500}
358	rack	UPDATE	101	2025-03-29 22:00:01.003071	{"roomid": 21, "rack_id": 101, "rack_number": 10}	{"roomid": 21, "rack_id": 101, "rack_number": 520}
359	rack	UPDATE	102	2025-03-29 22:00:01.003071	{"roomid": 21, "rack_id": 102, "rack_number": 20}	{"roomid": 21, "rack_id": 102, "rack_number": 530}
360	rack	UPDATE	103	2025-03-29 22:00:01.003071	{"roomid": 21, "rack_id": 103, "rack_number": 30}	{"roomid": 21, "rack_id": 103, "rack_number": 540}
361	rack	UPDATE	104	2025-03-29 22:00:01.003071	{"roomid": 21, "rack_id": 104, "rack_number": 40}	{"roomid": 21, "rack_id": 104, "rack_number": 550}
362	rack	UPDATE	105	2025-03-29 22:00:01.003071	{"roomid": 21, "rack_id": 105, "rack_number": 50}	{"roomid": 21, "rack_id": 105, "rack_number": 560}
363	rack	UPDATE	106	2025-03-29 22:00:01.003071	{"roomid": 22, "rack_id": 106, "rack_number": 10}	{"roomid": 22, "rack_id": 106, "rack_number": 530}
364	rack	UPDATE	107	2025-03-29 22:00:01.003071	{"roomid": 22, "rack_id": 107, "rack_number": 20}	{"roomid": 22, "rack_id": 107, "rack_number": 540}
365	rack	UPDATE	108	2025-03-29 22:00:01.003071	{"roomid": 22, "rack_id": 108, "rack_number": 30}	{"roomid": 22, "rack_id": 108, "rack_number": 550}
366	rack	UPDATE	109	2025-03-29 22:00:01.003071	{"roomid": 22, "rack_id": 109, "rack_number": 40}	{"roomid": 22, "rack_id": 109, "rack_number": 560}
367	rack	UPDATE	110	2025-03-29 22:00:01.003071	{"roomid": 22, "rack_id": 110, "rack_number": 50}	{"roomid": 22, "rack_id": 110, "rack_number": 570}
368	rack	UPDATE	111	2025-03-29 22:00:01.003071	{"roomid": 23, "rack_id": 111, "rack_number": 10}	{"roomid": 23, "rack_id": 111, "rack_number": 540}
369	rack	UPDATE	112	2025-03-29 22:00:01.003071	{"roomid": 23, "rack_id": 112, "rack_number": 20}	{"roomid": 23, "rack_id": 112, "rack_number": 550}
370	rack	UPDATE	113	2025-03-29 22:00:01.003071	{"roomid": 23, "rack_id": 113, "rack_number": 30}	{"roomid": 23, "rack_id": 113, "rack_number": 560}
371	rack	UPDATE	114	2025-03-29 22:00:01.003071	{"roomid": 23, "rack_id": 114, "rack_number": 40}	{"roomid": 23, "rack_id": 114, "rack_number": 570}
372	rack	UPDATE	115	2025-03-29 22:00:01.003071	{"roomid": 23, "rack_id": 115, "rack_number": 50}	{"roomid": 23, "rack_id": 115, "rack_number": 580}
373	rack	UPDATE	116	2025-03-29 22:00:01.003071	{"roomid": 24, "rack_id": 116, "rack_number": 10}	{"roomid": 24, "rack_id": 116, "rack_number": 550}
374	rack	UPDATE	117	2025-03-29 22:00:01.003071	{"roomid": 24, "rack_id": 117, "rack_number": 20}	{"roomid": 24, "rack_id": 117, "rack_number": 560}
375	rack	UPDATE	118	2025-03-29 22:00:01.003071	{"roomid": 24, "rack_id": 118, "rack_number": 30}	{"roomid": 24, "rack_id": 118, "rack_number": 570}
376	rack	UPDATE	119	2025-03-29 22:00:01.003071	{"roomid": 24, "rack_id": 119, "rack_number": 40}	{"roomid": 24, "rack_id": 119, "rack_number": 580}
377	rack	UPDATE	120	2025-03-29 22:00:01.003071	{"roomid": 24, "rack_id": 120, "rack_number": 50}	{"roomid": 24, "rack_id": 120, "rack_number": 590}
378	rack	UPDATE	121	2025-03-29 22:00:01.003071	{"roomid": 25, "rack_id": 121, "rack_number": 10}	{"roomid": 25, "rack_id": 121, "rack_number": 560}
379	rack	UPDATE	122	2025-03-29 22:00:01.003071	{"roomid": 25, "rack_id": 122, "rack_number": 20}	{"roomid": 25, "rack_id": 122, "rack_number": 570}
380	rack	UPDATE	123	2025-03-29 22:00:01.003071	{"roomid": 25, "rack_id": 123, "rack_number": 30}	{"roomid": 25, "rack_id": 123, "rack_number": 580}
381	rack	UPDATE	124	2025-03-29 22:00:01.003071	{"roomid": 25, "rack_id": 124, "rack_number": 40}	{"roomid": 25, "rack_id": 124, "rack_number": 590}
382	rack	UPDATE	125	2025-03-29 22:00:01.003071	{"roomid": 25, "rack_id": 125, "rack_number": 50}	{"roomid": 25, "rack_id": 125, "rack_number": 600}
383	rack	UPDATE	126	2025-03-29 22:00:01.003071	{"roomid": 26, "rack_id": 126, "rack_number": 10}	{"roomid": 26, "rack_id": 126, "rack_number": 620}
384	shelf	UPDATE	1	2025-03-29 22:01:14.971228	{"rackid": 1, "shelf_id": 1, "shelf_number": 100}	{"rackid": 1, "shelf_id": 1, "shelf_number": 1300}
385	shelf	UPDATE	2	2025-03-29 22:01:14.971228	{"rackid": 1, "shelf_id": 2, "shelf_number": 200}	{"rackid": 1, "shelf_id": 2, "shelf_number": 1400}
386	shelf	UPDATE	3	2025-03-29 22:01:14.971228	{"rackid": 1, "shelf_id": 3, "shelf_number": 300}	{"rackid": 1, "shelf_id": 3, "shelf_number": 1500}
387	shelf	UPDATE	4	2025-03-29 22:01:14.971228	{"rackid": 1, "shelf_id": 4, "shelf_number": 400}	{"rackid": 1, "shelf_id": 4, "shelf_number": 1600}
388	shelf	UPDATE	5	2025-03-29 22:01:14.971228	{"rackid": 1, "shelf_id": 5, "shelf_number": 500}	{"rackid": 1, "shelf_id": 5, "shelf_number": 1700}
389	shelf	UPDATE	6	2025-03-29 22:01:14.971228	{"rackid": 2, "shelf_id": 6, "shelf_number": 100}	{"rackid": 2, "shelf_id": 6, "shelf_number": 1400}
390	shelf	UPDATE	7	2025-03-29 22:01:14.971228	{"rackid": 2, "shelf_id": 7, "shelf_number": 200}	{"rackid": 2, "shelf_id": 7, "shelf_number": 1500}
391	shelf	UPDATE	8	2025-03-29 22:01:14.971228	{"rackid": 2, "shelf_id": 8, "shelf_number": 300}	{"rackid": 2, "shelf_id": 8, "shelf_number": 1600}
392	shelf	UPDATE	9	2025-03-29 22:01:14.971228	{"rackid": 2, "shelf_id": 9, "shelf_number": 400}	{"rackid": 2, "shelf_id": 9, "shelf_number": 1700}
393	shelf	UPDATE	10	2025-03-29 22:01:14.971228	{"rackid": 2, "shelf_id": 10, "shelf_number": 500}	{"rackid": 2, "shelf_id": 10, "shelf_number": 1800}
394	shelf	UPDATE	11	2025-03-29 22:01:14.971228	{"rackid": 3, "shelf_id": 11, "shelf_number": 100}	{"rackid": 3, "shelf_id": 11, "shelf_number": 1500}
395	shelf	UPDATE	12	2025-03-29 22:01:14.971228	{"rackid": 3, "shelf_id": 12, "shelf_number": 200}	{"rackid": 3, "shelf_id": 12, "shelf_number": 1600}
396	shelf	UPDATE	13	2025-03-29 22:01:14.971228	{"rackid": 3, "shelf_id": 13, "shelf_number": 300}	{"rackid": 3, "shelf_id": 13, "shelf_number": 1700}
397	shelf	UPDATE	14	2025-03-29 22:01:14.971228	{"rackid": 3, "shelf_id": 14, "shelf_number": 400}	{"rackid": 3, "shelf_id": 14, "shelf_number": 1800}
398	shelf	UPDATE	15	2025-03-29 22:01:14.971228	{"rackid": 3, "shelf_id": 15, "shelf_number": 500}	{"rackid": 3, "shelf_id": 15, "shelf_number": 1900}
399	shelf	UPDATE	16	2025-03-29 22:01:14.971228	{"rackid": 4, "shelf_id": 16, "shelf_number": 100}	{"rackid": 4, "shelf_id": 16, "shelf_number": 1600}
400	shelf	UPDATE	17	2025-03-29 22:01:14.971228	{"rackid": 4, "shelf_id": 17, "shelf_number": 200}	{"rackid": 4, "shelf_id": 17, "shelf_number": 1700}
401	shelf	UPDATE	18	2025-03-29 22:01:14.971228	{"rackid": 4, "shelf_id": 18, "shelf_number": 300}	{"rackid": 4, "shelf_id": 18, "shelf_number": 1800}
402	shelf	UPDATE	19	2025-03-29 22:01:14.971228	{"rackid": 4, "shelf_id": 19, "shelf_number": 400}	{"rackid": 4, "shelf_id": 19, "shelf_number": 1900}
403	shelf	UPDATE	20	2025-03-29 22:01:14.971228	{"rackid": 4, "shelf_id": 20, "shelf_number": 500}	{"rackid": 4, "shelf_id": 20, "shelf_number": 2000}
404	shelf	UPDATE	21	2025-03-29 22:01:14.971228	{"rackid": 5, "shelf_id": 21, "shelf_number": 100}	{"rackid": 5, "shelf_id": 21, "shelf_number": 1700}
405	shelf	UPDATE	22	2025-03-29 22:01:14.971228	{"rackid": 5, "shelf_id": 22, "shelf_number": 200}	{"rackid": 5, "shelf_id": 22, "shelf_number": 1800}
406	shelf	UPDATE	23	2025-03-29 22:01:14.971228	{"rackid": 5, "shelf_id": 23, "shelf_number": 300}	{"rackid": 5, "shelf_id": 23, "shelf_number": 1900}
407	shelf	UPDATE	24	2025-03-29 22:01:14.971228	{"rackid": 5, "shelf_id": 24, "shelf_number": 400}	{"rackid": 5, "shelf_id": 24, "shelf_number": 2000}
408	shelf	UPDATE	25	2025-03-29 22:01:14.971228	{"rackid": 5, "shelf_id": 25, "shelf_number": 500}	{"rackid": 5, "shelf_id": 25, "shelf_number": 2100}
409	shelf	UPDATE	26	2025-03-29 22:01:14.971228	{"rackid": 6, "shelf_id": 26, "shelf_number": 100}	{"rackid": 6, "shelf_id": 26, "shelf_number": 1400}
410	shelf	UPDATE	27	2025-03-29 22:01:14.971228	{"rackid": 6, "shelf_id": 27, "shelf_number": 200}	{"rackid": 6, "shelf_id": 27, "shelf_number": 1500}
411	shelf	UPDATE	28	2025-03-29 22:01:14.971228	{"rackid": 6, "shelf_id": 28, "shelf_number": 300}	{"rackid": 6, "shelf_id": 28, "shelf_number": 1600}
412	shelf	UPDATE	29	2025-03-29 22:01:14.971228	{"rackid": 6, "shelf_id": 29, "shelf_number": 400}	{"rackid": 6, "shelf_id": 29, "shelf_number": 1700}
413	shelf	UPDATE	30	2025-03-29 22:01:14.971228	{"rackid": 6, "shelf_id": 30, "shelf_number": 500}	{"rackid": 6, "shelf_id": 30, "shelf_number": 1800}
414	shelf	UPDATE	31	2025-03-29 22:01:14.971228	{"rackid": 7, "shelf_id": 31, "shelf_number": 100}	{"rackid": 7, "shelf_id": 31, "shelf_number": 1500}
415	shelf	UPDATE	32	2025-03-29 22:01:14.971228	{"rackid": 7, "shelf_id": 32, "shelf_number": 200}	{"rackid": 7, "shelf_id": 32, "shelf_number": 1600}
416	shelf	UPDATE	33	2025-03-29 22:01:14.971228	{"rackid": 7, "shelf_id": 33, "shelf_number": 300}	{"rackid": 7, "shelf_id": 33, "shelf_number": 1700}
417	shelf	UPDATE	34	2025-03-29 22:01:14.971228	{"rackid": 7, "shelf_id": 34, "shelf_number": 400}	{"rackid": 7, "shelf_id": 34, "shelf_number": 1800}
418	shelf	UPDATE	35	2025-03-29 22:01:14.971228	{"rackid": 7, "shelf_id": 35, "shelf_number": 500}	{"rackid": 7, "shelf_id": 35, "shelf_number": 1900}
419	shelf	UPDATE	36	2025-03-29 22:01:14.971228	{"rackid": 8, "shelf_id": 36, "shelf_number": 100}	{"rackid": 8, "shelf_id": 36, "shelf_number": 1600}
420	shelf	UPDATE	37	2025-03-29 22:01:14.971228	{"rackid": 8, "shelf_id": 37, "shelf_number": 200}	{"rackid": 8, "shelf_id": 37, "shelf_number": 1700}
421	shelf	UPDATE	38	2025-03-29 22:01:14.971228	{"rackid": 8, "shelf_id": 38, "shelf_number": 300}	{"rackid": 8, "shelf_id": 38, "shelf_number": 1800}
422	shelf	UPDATE	39	2025-03-29 22:01:14.971228	{"rackid": 8, "shelf_id": 39, "shelf_number": 400}	{"rackid": 8, "shelf_id": 39, "shelf_number": 1900}
423	shelf	UPDATE	40	2025-03-29 22:01:14.971228	{"rackid": 8, "shelf_id": 40, "shelf_number": 500}	{"rackid": 8, "shelf_id": 40, "shelf_number": 2000}
424	shelf	UPDATE	41	2025-03-29 22:01:14.971228	{"rackid": 9, "shelf_id": 41, "shelf_number": 100}	{"rackid": 9, "shelf_id": 41, "shelf_number": 1700}
425	shelf	UPDATE	42	2025-03-29 22:01:14.971228	{"rackid": 9, "shelf_id": 42, "shelf_number": 200}	{"rackid": 9, "shelf_id": 42, "shelf_number": 1800}
426	shelf	UPDATE	43	2025-03-29 22:01:14.971228	{"rackid": 9, "shelf_id": 43, "shelf_number": 300}	{"rackid": 9, "shelf_id": 43, "shelf_number": 1900}
427	shelf	UPDATE	44	2025-03-29 22:01:14.971228	{"rackid": 9, "shelf_id": 44, "shelf_number": 400}	{"rackid": 9, "shelf_id": 44, "shelf_number": 2000}
428	shelf	UPDATE	45	2025-03-29 22:01:14.971228	{"rackid": 9, "shelf_id": 45, "shelf_number": 500}	{"rackid": 9, "shelf_id": 45, "shelf_number": 2100}
429	shelf	UPDATE	46	2025-03-29 22:01:14.971228	{"rackid": 10, "shelf_id": 46, "shelf_number": 100}	{"rackid": 10, "shelf_id": 46, "shelf_number": 1800}
430	shelf	UPDATE	47	2025-03-29 22:01:14.971228	{"rackid": 10, "shelf_id": 47, "shelf_number": 200}	{"rackid": 10, "shelf_id": 47, "shelf_number": 1900}
431	shelf	UPDATE	48	2025-03-29 22:01:14.971228	{"rackid": 10, "shelf_id": 48, "shelf_number": 300}	{"rackid": 10, "shelf_id": 48, "shelf_number": 2000}
432	shelf	UPDATE	49	2025-03-29 22:01:14.971228	{"rackid": 10, "shelf_id": 49, "shelf_number": 400}	{"rackid": 10, "shelf_id": 49, "shelf_number": 2100}
433	shelf	UPDATE	50	2025-03-29 22:01:14.971228	{"rackid": 10, "shelf_id": 50, "shelf_number": 500}	{"rackid": 10, "shelf_id": 50, "shelf_number": 2200}
434	shelf	UPDATE	51	2025-03-29 22:01:14.971228	{"rackid": 11, "shelf_id": 51, "shelf_number": 100}	{"rackid": 11, "shelf_id": 51, "shelf_number": 1500}
435	shelf	UPDATE	52	2025-03-29 22:01:14.971228	{"rackid": 11, "shelf_id": 52, "shelf_number": 200}	{"rackid": 11, "shelf_id": 52, "shelf_number": 1600}
436	shelf	UPDATE	53	2025-03-29 22:01:14.971228	{"rackid": 11, "shelf_id": 53, "shelf_number": 300}	{"rackid": 11, "shelf_id": 53, "shelf_number": 1700}
437	shelf	UPDATE	54	2025-03-29 22:01:14.971228	{"rackid": 11, "shelf_id": 54, "shelf_number": 400}	{"rackid": 11, "shelf_id": 54, "shelf_number": 1800}
438	shelf	UPDATE	55	2025-03-29 22:01:14.971228	{"rackid": 11, "shelf_id": 55, "shelf_number": 500}	{"rackid": 11, "shelf_id": 55, "shelf_number": 1900}
439	shelf	UPDATE	56	2025-03-29 22:01:14.971228	{"rackid": 12, "shelf_id": 56, "shelf_number": 100}	{"rackid": 12, "shelf_id": 56, "shelf_number": 1600}
440	shelf	UPDATE	57	2025-03-29 22:01:14.971228	{"rackid": 12, "shelf_id": 57, "shelf_number": 200}	{"rackid": 12, "shelf_id": 57, "shelf_number": 1700}
441	shelf	UPDATE	58	2025-03-29 22:01:14.971228	{"rackid": 12, "shelf_id": 58, "shelf_number": 300}	{"rackid": 12, "shelf_id": 58, "shelf_number": 1800}
442	shelf	UPDATE	59	2025-03-29 22:01:14.971228	{"rackid": 12, "shelf_id": 59, "shelf_number": 400}	{"rackid": 12, "shelf_id": 59, "shelf_number": 1900}
443	shelf	UPDATE	60	2025-03-29 22:01:14.971228	{"rackid": 12, "shelf_id": 60, "shelf_number": 500}	{"rackid": 12, "shelf_id": 60, "shelf_number": 2000}
444	shelf	UPDATE	61	2025-03-29 22:01:14.971228	{"rackid": 13, "shelf_id": 61, "shelf_number": 100}	{"rackid": 13, "shelf_id": 61, "shelf_number": 1700}
445	shelf	UPDATE	62	2025-03-29 22:01:14.971228	{"rackid": 13, "shelf_id": 62, "shelf_number": 200}	{"rackid": 13, "shelf_id": 62, "shelf_number": 1800}
446	shelf	UPDATE	63	2025-03-29 22:01:14.971228	{"rackid": 13, "shelf_id": 63, "shelf_number": 300}	{"rackid": 13, "shelf_id": 63, "shelf_number": 1900}
447	shelf	UPDATE	64	2025-03-29 22:01:14.971228	{"rackid": 13, "shelf_id": 64, "shelf_number": 400}	{"rackid": 13, "shelf_id": 64, "shelf_number": 2000}
448	shelf	UPDATE	65	2025-03-29 22:01:14.971228	{"rackid": 13, "shelf_id": 65, "shelf_number": 500}	{"rackid": 13, "shelf_id": 65, "shelf_number": 2100}
449	shelf	UPDATE	66	2025-03-29 22:01:14.971228	{"rackid": 14, "shelf_id": 66, "shelf_number": 100}	{"rackid": 14, "shelf_id": 66, "shelf_number": 1800}
450	shelf	UPDATE	67	2025-03-29 22:01:14.971228	{"rackid": 14, "shelf_id": 67, "shelf_number": 200}	{"rackid": 14, "shelf_id": 67, "shelf_number": 1900}
451	shelf	UPDATE	68	2025-03-29 22:01:14.971228	{"rackid": 14, "shelf_id": 68, "shelf_number": 300}	{"rackid": 14, "shelf_id": 68, "shelf_number": 2000}
452	shelf	UPDATE	69	2025-03-29 22:01:14.971228	{"rackid": 14, "shelf_id": 69, "shelf_number": 400}	{"rackid": 14, "shelf_id": 69, "shelf_number": 2100}
453	shelf	UPDATE	70	2025-03-29 22:01:14.971228	{"rackid": 14, "shelf_id": 70, "shelf_number": 500}	{"rackid": 14, "shelf_id": 70, "shelf_number": 2200}
454	shelf	UPDATE	71	2025-03-29 22:01:14.971228	{"rackid": 15, "shelf_id": 71, "shelf_number": 100}	{"rackid": 15, "shelf_id": 71, "shelf_number": 1900}
455	shelf	UPDATE	72	2025-03-29 22:01:14.971228	{"rackid": 15, "shelf_id": 72, "shelf_number": 200}	{"rackid": 15, "shelf_id": 72, "shelf_number": 2000}
456	shelf	UPDATE	73	2025-03-29 22:01:14.971228	{"rackid": 15, "shelf_id": 73, "shelf_number": 300}	{"rackid": 15, "shelf_id": 73, "shelf_number": 2100}
457	shelf	UPDATE	74	2025-03-29 22:01:14.971228	{"rackid": 15, "shelf_id": 74, "shelf_number": 400}	{"rackid": 15, "shelf_id": 74, "shelf_number": 2200}
458	shelf	UPDATE	75	2025-03-29 22:01:14.971228	{"rackid": 15, "shelf_id": 75, "shelf_number": 500}	{"rackid": 15, "shelf_id": 75, "shelf_number": 2300}
459	shelf	UPDATE	76	2025-03-29 22:01:14.971228	{"rackid": 16, "shelf_id": 76, "shelf_number": 100}	{"rackid": 16, "shelf_id": 76, "shelf_number": 1600}
460	shelf	UPDATE	77	2025-03-29 22:01:14.971228	{"rackid": 16, "shelf_id": 77, "shelf_number": 200}	{"rackid": 16, "shelf_id": 77, "shelf_number": 1700}
461	shelf	UPDATE	78	2025-03-29 22:01:14.971228	{"rackid": 16, "shelf_id": 78, "shelf_number": 300}	{"rackid": 16, "shelf_id": 78, "shelf_number": 1800}
462	shelf	UPDATE	79	2025-03-29 22:01:14.971228	{"rackid": 16, "shelf_id": 79, "shelf_number": 400}	{"rackid": 16, "shelf_id": 79, "shelf_number": 1900}
463	shelf	UPDATE	80	2025-03-29 22:01:14.971228	{"rackid": 16, "shelf_id": 80, "shelf_number": 500}	{"rackid": 16, "shelf_id": 80, "shelf_number": 2000}
464	shelf	UPDATE	81	2025-03-29 22:01:14.971228	{"rackid": 17, "shelf_id": 81, "shelf_number": 100}	{"rackid": 17, "shelf_id": 81, "shelf_number": 1700}
465	shelf	UPDATE	82	2025-03-29 22:01:14.971228	{"rackid": 17, "shelf_id": 82, "shelf_number": 200}	{"rackid": 17, "shelf_id": 82, "shelf_number": 1800}
466	shelf	UPDATE	83	2025-03-29 22:01:14.971228	{"rackid": 17, "shelf_id": 83, "shelf_number": 300}	{"rackid": 17, "shelf_id": 83, "shelf_number": 1900}
467	shelf	UPDATE	84	2025-03-29 22:01:14.971228	{"rackid": 17, "shelf_id": 84, "shelf_number": 400}	{"rackid": 17, "shelf_id": 84, "shelf_number": 2000}
468	shelf	UPDATE	85	2025-03-29 22:01:14.971228	{"rackid": 17, "shelf_id": 85, "shelf_number": 500}	{"rackid": 17, "shelf_id": 85, "shelf_number": 2100}
469	shelf	UPDATE	86	2025-03-29 22:01:14.971228	{"rackid": 18, "shelf_id": 86, "shelf_number": 100}	{"rackid": 18, "shelf_id": 86, "shelf_number": 1800}
470	shelf	UPDATE	87	2025-03-29 22:01:14.971228	{"rackid": 18, "shelf_id": 87, "shelf_number": 200}	{"rackid": 18, "shelf_id": 87, "shelf_number": 1900}
471	shelf	UPDATE	88	2025-03-29 22:01:14.971228	{"rackid": 18, "shelf_id": 88, "shelf_number": 300}	{"rackid": 18, "shelf_id": 88, "shelf_number": 2000}
472	shelf	UPDATE	89	2025-03-29 22:01:14.971228	{"rackid": 18, "shelf_id": 89, "shelf_number": 400}	{"rackid": 18, "shelf_id": 89, "shelf_number": 2100}
473	shelf	UPDATE	90	2025-03-29 22:01:14.971228	{"rackid": 18, "shelf_id": 90, "shelf_number": 500}	{"rackid": 18, "shelf_id": 90, "shelf_number": 2200}
474	shelf	UPDATE	91	2025-03-29 22:01:14.971228	{"rackid": 19, "shelf_id": 91, "shelf_number": 100}	{"rackid": 19, "shelf_id": 91, "shelf_number": 1900}
475	shelf	UPDATE	92	2025-03-29 22:01:14.971228	{"rackid": 19, "shelf_id": 92, "shelf_number": 200}	{"rackid": 19, "shelf_id": 92, "shelf_number": 2000}
476	shelf	UPDATE	93	2025-03-29 22:01:14.971228	{"rackid": 19, "shelf_id": 93, "shelf_number": 300}	{"rackid": 19, "shelf_id": 93, "shelf_number": 2100}
477	shelf	UPDATE	94	2025-03-29 22:01:14.971228	{"rackid": 19, "shelf_id": 94, "shelf_number": 400}	{"rackid": 19, "shelf_id": 94, "shelf_number": 2200}
478	shelf	UPDATE	95	2025-03-29 22:01:14.971228	{"rackid": 19, "shelf_id": 95, "shelf_number": 500}	{"rackid": 19, "shelf_id": 95, "shelf_number": 2300}
479	shelf	UPDATE	96	2025-03-29 22:01:14.971228	{"rackid": 20, "shelf_id": 96, "shelf_number": 100}	{"rackid": 20, "shelf_id": 96, "shelf_number": 2000}
480	shelf	UPDATE	97	2025-03-29 22:01:14.971228	{"rackid": 20, "shelf_id": 97, "shelf_number": 200}	{"rackid": 20, "shelf_id": 97, "shelf_number": 2100}
481	shelf	UPDATE	98	2025-03-29 22:01:14.971228	{"rackid": 20, "shelf_id": 98, "shelf_number": 300}	{"rackid": 20, "shelf_id": 98, "shelf_number": 2200}
482	shelf	UPDATE	99	2025-03-29 22:01:14.971228	{"rackid": 20, "shelf_id": 99, "shelf_number": 400}	{"rackid": 20, "shelf_id": 99, "shelf_number": 2300}
483	shelf	UPDATE	100	2025-03-29 22:01:14.971228	{"rackid": 20, "shelf_id": 100, "shelf_number": 500}	{"rackid": 20, "shelf_id": 100, "shelf_number": 2400}
484	shelf	UPDATE	101	2025-03-29 22:01:14.971228	{"rackid": 21, "shelf_id": 101, "shelf_number": 100}	{"rackid": 21, "shelf_id": 101, "shelf_number": 1700}
485	shelf	UPDATE	102	2025-03-29 22:01:14.971228	{"rackid": 21, "shelf_id": 102, "shelf_number": 200}	{"rackid": 21, "shelf_id": 102, "shelf_number": 1800}
486	shelf	UPDATE	103	2025-03-29 22:01:14.971228	{"rackid": 21, "shelf_id": 103, "shelf_number": 300}	{"rackid": 21, "shelf_id": 103, "shelf_number": 1900}
487	shelf	UPDATE	104	2025-03-29 22:01:14.971228	{"rackid": 21, "shelf_id": 104, "shelf_number": 400}	{"rackid": 21, "shelf_id": 104, "shelf_number": 2000}
488	shelf	UPDATE	105	2025-03-29 22:01:14.971228	{"rackid": 21, "shelf_id": 105, "shelf_number": 500}	{"rackid": 21, "shelf_id": 105, "shelf_number": 2100}
489	shelf	UPDATE	106	2025-03-29 22:01:14.971228	{"rackid": 22, "shelf_id": 106, "shelf_number": 100}	{"rackid": 22, "shelf_id": 106, "shelf_number": 1800}
490	shelf	UPDATE	107	2025-03-29 22:01:14.971228	{"rackid": 22, "shelf_id": 107, "shelf_number": 200}	{"rackid": 22, "shelf_id": 107, "shelf_number": 1900}
491	shelf	UPDATE	108	2025-03-29 22:01:14.971228	{"rackid": 22, "shelf_id": 108, "shelf_number": 300}	{"rackid": 22, "shelf_id": 108, "shelf_number": 2000}
492	shelf	UPDATE	109	2025-03-29 22:01:14.971228	{"rackid": 22, "shelf_id": 109, "shelf_number": 400}	{"rackid": 22, "shelf_id": 109, "shelf_number": 2100}
493	shelf	UPDATE	110	2025-03-29 22:01:14.971228	{"rackid": 22, "shelf_id": 110, "shelf_number": 500}	{"rackid": 22, "shelf_id": 110, "shelf_number": 2200}
494	shelf	UPDATE	111	2025-03-29 22:01:14.971228	{"rackid": 23, "shelf_id": 111, "shelf_number": 100}	{"rackid": 23, "shelf_id": 111, "shelf_number": 1900}
495	shelf	UPDATE	112	2025-03-29 22:01:14.971228	{"rackid": 23, "shelf_id": 112, "shelf_number": 200}	{"rackid": 23, "shelf_id": 112, "shelf_number": 2000}
496	shelf	UPDATE	113	2025-03-29 22:01:14.971228	{"rackid": 23, "shelf_id": 113, "shelf_number": 300}	{"rackid": 23, "shelf_id": 113, "shelf_number": 2100}
497	shelf	UPDATE	114	2025-03-29 22:01:14.971228	{"rackid": 23, "shelf_id": 114, "shelf_number": 400}	{"rackid": 23, "shelf_id": 114, "shelf_number": 2200}
498	shelf	UPDATE	115	2025-03-29 22:01:14.971228	{"rackid": 23, "shelf_id": 115, "shelf_number": 500}	{"rackid": 23, "shelf_id": 115, "shelf_number": 2300}
499	shelf	UPDATE	116	2025-03-29 22:01:14.971228	{"rackid": 24, "shelf_id": 116, "shelf_number": 100}	{"rackid": 24, "shelf_id": 116, "shelf_number": 2000}
500	shelf	UPDATE	117	2025-03-29 22:01:14.971228	{"rackid": 24, "shelf_id": 117, "shelf_number": 200}	{"rackid": 24, "shelf_id": 117, "shelf_number": 2100}
501	shelf	UPDATE	118	2025-03-29 22:01:14.971228	{"rackid": 24, "shelf_id": 118, "shelf_number": 300}	{"rackid": 24, "shelf_id": 118, "shelf_number": 2200}
502	shelf	UPDATE	119	2025-03-29 22:01:14.971228	{"rackid": 24, "shelf_id": 119, "shelf_number": 400}	{"rackid": 24, "shelf_id": 119, "shelf_number": 2300}
503	shelf	UPDATE	120	2025-03-29 22:01:14.971228	{"rackid": 24, "shelf_id": 120, "shelf_number": 500}	{"rackid": 24, "shelf_id": 120, "shelf_number": 2400}
504	shelf	UPDATE	121	2025-03-29 22:01:14.971228	{"rackid": 25, "shelf_id": 121, "shelf_number": 100}	{"rackid": 25, "shelf_id": 121, "shelf_number": 2100}
505	shelf	UPDATE	122	2025-03-29 22:01:14.971228	{"rackid": 25, "shelf_id": 122, "shelf_number": 200}	{"rackid": 25, "shelf_id": 122, "shelf_number": 2200}
506	shelf	UPDATE	123	2025-03-29 22:01:14.971228	{"rackid": 25, "shelf_id": 123, "shelf_number": 300}	{"rackid": 25, "shelf_id": 123, "shelf_number": 2300}
507	shelf	UPDATE	124	2025-03-29 22:01:14.971228	{"rackid": 25, "shelf_id": 124, "shelf_number": 400}	{"rackid": 25, "shelf_id": 124, "shelf_number": 2400}
508	shelf	UPDATE	125	2025-03-29 22:01:14.971228	{"rackid": 25, "shelf_id": 125, "shelf_number": 500}	{"rackid": 25, "shelf_id": 125, "shelf_number": 2500}
509	shelf	UPDATE	126	2025-03-29 22:01:14.971228	{"rackid": 26, "shelf_id": 126, "shelf_number": 100}	{"rackid": 26, "shelf_id": 126, "shelf_number": 2300}
510	shelf	UPDATE	127	2025-03-29 22:01:14.971228	{"rackid": 26, "shelf_id": 127, "shelf_number": 200}	{"rackid": 26, "shelf_id": 127, "shelf_number": 2400}
511	shelf	UPDATE	128	2025-03-29 22:01:14.971228	{"rackid": 26, "shelf_id": 128, "shelf_number": 300}	{"rackid": 26, "shelf_id": 128, "shelf_number": 2500}
512	shelf	UPDATE	129	2025-03-29 22:01:14.971228	{"rackid": 26, "shelf_id": 129, "shelf_number": 400}	{"rackid": 26, "shelf_id": 129, "shelf_number": 2600}
513	shelf	UPDATE	130	2025-03-29 22:01:14.971228	{"rackid": 26, "shelf_id": 130, "shelf_number": 500}	{"rackid": 26, "shelf_id": 130, "shelf_number": 2700}
514	shelf	UPDATE	131	2025-03-29 22:01:14.971228	{"rackid": 27, "shelf_id": 131, "shelf_number": 100}	{"rackid": 27, "shelf_id": 131, "shelf_number": 2400}
515	shelf	UPDATE	132	2025-03-29 22:01:14.971228	{"rackid": 27, "shelf_id": 132, "shelf_number": 200}	{"rackid": 27, "shelf_id": 132, "shelf_number": 2500}
516	shelf	UPDATE	133	2025-03-29 22:01:14.971228	{"rackid": 27, "shelf_id": 133, "shelf_number": 300}	{"rackid": 27, "shelf_id": 133, "shelf_number": 2600}
517	shelf	UPDATE	134	2025-03-29 22:01:14.971228	{"rackid": 27, "shelf_id": 134, "shelf_number": 400}	{"rackid": 27, "shelf_id": 134, "shelf_number": 2700}
518	shelf	UPDATE	135	2025-03-29 22:01:14.971228	{"rackid": 27, "shelf_id": 135, "shelf_number": 500}	{"rackid": 27, "shelf_id": 135, "shelf_number": 2800}
519	shelf	UPDATE	136	2025-03-29 22:01:14.971228	{"rackid": 28, "shelf_id": 136, "shelf_number": 100}	{"rackid": 28, "shelf_id": 136, "shelf_number": 2500}
520	shelf	UPDATE	137	2025-03-29 22:01:14.971228	{"rackid": 28, "shelf_id": 137, "shelf_number": 200}	{"rackid": 28, "shelf_id": 137, "shelf_number": 2600}
521	shelf	UPDATE	138	2025-03-29 22:01:14.971228	{"rackid": 28, "shelf_id": 138, "shelf_number": 300}	{"rackid": 28, "shelf_id": 138, "shelf_number": 2700}
522	shelf	UPDATE	139	2025-03-29 22:01:14.971228	{"rackid": 28, "shelf_id": 139, "shelf_number": 400}	{"rackid": 28, "shelf_id": 139, "shelf_number": 2800}
523	shelf	UPDATE	140	2025-03-29 22:01:14.971228	{"rackid": 28, "shelf_id": 140, "shelf_number": 500}	{"rackid": 28, "shelf_id": 140, "shelf_number": 2900}
524	shelf	UPDATE	141	2025-03-29 22:01:14.971228	{"rackid": 29, "shelf_id": 141, "shelf_number": 100}	{"rackid": 29, "shelf_id": 141, "shelf_number": 2600}
525	shelf	UPDATE	142	2025-03-29 22:01:14.971228	{"rackid": 29, "shelf_id": 142, "shelf_number": 200}	{"rackid": 29, "shelf_id": 142, "shelf_number": 2700}
526	shelf	UPDATE	143	2025-03-29 22:01:14.971228	{"rackid": 29, "shelf_id": 143, "shelf_number": 300}	{"rackid": 29, "shelf_id": 143, "shelf_number": 2800}
527	shelf	UPDATE	144	2025-03-29 22:01:14.971228	{"rackid": 29, "shelf_id": 144, "shelf_number": 400}	{"rackid": 29, "shelf_id": 144, "shelf_number": 2900}
528	shelf	UPDATE	145	2025-03-29 22:01:14.971228	{"rackid": 29, "shelf_id": 145, "shelf_number": 500}	{"rackid": 29, "shelf_id": 145, "shelf_number": 3000}
529	shelf	UPDATE	146	2025-03-29 22:01:14.971228	{"rackid": 30, "shelf_id": 146, "shelf_number": 100}	{"rackid": 30, "shelf_id": 146, "shelf_number": 2700}
530	shelf	UPDATE	147	2025-03-29 22:01:14.971228	{"rackid": 30, "shelf_id": 147, "shelf_number": 200}	{"rackid": 30, "shelf_id": 147, "shelf_number": 2800}
531	shelf	UPDATE	148	2025-03-29 22:01:14.971228	{"rackid": 30, "shelf_id": 148, "shelf_number": 300}	{"rackid": 30, "shelf_id": 148, "shelf_number": 2900}
532	shelf	UPDATE	149	2025-03-29 22:01:14.971228	{"rackid": 30, "shelf_id": 149, "shelf_number": 400}	{"rackid": 30, "shelf_id": 149, "shelf_number": 3000}
533	shelf	UPDATE	150	2025-03-29 22:01:14.971228	{"rackid": 30, "shelf_id": 150, "shelf_number": 500}	{"rackid": 30, "shelf_id": 150, "shelf_number": 3100}
534	shelf	UPDATE	151	2025-03-29 22:01:14.971228	{"rackid": 31, "shelf_id": 151, "shelf_number": 100}	{"rackid": 31, "shelf_id": 151, "shelf_number": 2400}
535	shelf	UPDATE	152	2025-03-29 22:01:14.971228	{"rackid": 31, "shelf_id": 152, "shelf_number": 200}	{"rackid": 31, "shelf_id": 152, "shelf_number": 2500}
536	shelf	UPDATE	153	2025-03-29 22:01:14.971228	{"rackid": 31, "shelf_id": 153, "shelf_number": 300}	{"rackid": 31, "shelf_id": 153, "shelf_number": 2600}
537	shelf	UPDATE	154	2025-03-29 22:01:14.971228	{"rackid": 31, "shelf_id": 154, "shelf_number": 400}	{"rackid": 31, "shelf_id": 154, "shelf_number": 2700}
538	shelf	UPDATE	155	2025-03-29 22:01:14.971228	{"rackid": 31, "shelf_id": 155, "shelf_number": 500}	{"rackid": 31, "shelf_id": 155, "shelf_number": 2800}
539	shelf	UPDATE	156	2025-03-29 22:01:14.971228	{"rackid": 32, "shelf_id": 156, "shelf_number": 100}	{"rackid": 32, "shelf_id": 156, "shelf_number": 2500}
540	shelf	UPDATE	157	2025-03-29 22:01:14.971228	{"rackid": 32, "shelf_id": 157, "shelf_number": 200}	{"rackid": 32, "shelf_id": 157, "shelf_number": 2600}
541	shelf	UPDATE	158	2025-03-29 22:01:14.971228	{"rackid": 32, "shelf_id": 158, "shelf_number": 300}	{"rackid": 32, "shelf_id": 158, "shelf_number": 2700}
542	shelf	UPDATE	159	2025-03-29 22:01:14.971228	{"rackid": 32, "shelf_id": 159, "shelf_number": 400}	{"rackid": 32, "shelf_id": 159, "shelf_number": 2800}
543	shelf	UPDATE	160	2025-03-29 22:01:14.971228	{"rackid": 32, "shelf_id": 160, "shelf_number": 500}	{"rackid": 32, "shelf_id": 160, "shelf_number": 2900}
544	shelf	UPDATE	161	2025-03-29 22:01:14.971228	{"rackid": 33, "shelf_id": 161, "shelf_number": 100}	{"rackid": 33, "shelf_id": 161, "shelf_number": 2600}
545	shelf	UPDATE	162	2025-03-29 22:01:14.971228	{"rackid": 33, "shelf_id": 162, "shelf_number": 200}	{"rackid": 33, "shelf_id": 162, "shelf_number": 2700}
546	shelf	UPDATE	163	2025-03-29 22:01:14.971228	{"rackid": 33, "shelf_id": 163, "shelf_number": 300}	{"rackid": 33, "shelf_id": 163, "shelf_number": 2800}
547	shelf	UPDATE	164	2025-03-29 22:01:14.971228	{"rackid": 33, "shelf_id": 164, "shelf_number": 400}	{"rackid": 33, "shelf_id": 164, "shelf_number": 2900}
548	shelf	UPDATE	165	2025-03-29 22:01:14.971228	{"rackid": 33, "shelf_id": 165, "shelf_number": 500}	{"rackid": 33, "shelf_id": 165, "shelf_number": 3000}
549	shelf	UPDATE	166	2025-03-29 22:01:14.971228	{"rackid": 34, "shelf_id": 166, "shelf_number": 100}	{"rackid": 34, "shelf_id": 166, "shelf_number": 2700}
550	shelf	UPDATE	167	2025-03-29 22:01:14.971228	{"rackid": 34, "shelf_id": 167, "shelf_number": 200}	{"rackid": 34, "shelf_id": 167, "shelf_number": 2800}
551	shelf	UPDATE	168	2025-03-29 22:01:14.971228	{"rackid": 34, "shelf_id": 168, "shelf_number": 300}	{"rackid": 34, "shelf_id": 168, "shelf_number": 2900}
552	shelf	UPDATE	169	2025-03-29 22:01:14.971228	{"rackid": 34, "shelf_id": 169, "shelf_number": 400}	{"rackid": 34, "shelf_id": 169, "shelf_number": 3000}
553	shelf	UPDATE	170	2025-03-29 22:01:14.971228	{"rackid": 34, "shelf_id": 170, "shelf_number": 500}	{"rackid": 34, "shelf_id": 170, "shelf_number": 3100}
554	shelf	UPDATE	171	2025-03-29 22:01:14.971228	{"rackid": 35, "shelf_id": 171, "shelf_number": 100}	{"rackid": 35, "shelf_id": 171, "shelf_number": 2800}
555	shelf	UPDATE	172	2025-03-29 22:01:14.971228	{"rackid": 35, "shelf_id": 172, "shelf_number": 200}	{"rackid": 35, "shelf_id": 172, "shelf_number": 2900}
556	shelf	UPDATE	173	2025-03-29 22:01:14.971228	{"rackid": 35, "shelf_id": 173, "shelf_number": 300}	{"rackid": 35, "shelf_id": 173, "shelf_number": 3000}
557	shelf	UPDATE	174	2025-03-29 22:01:14.971228	{"rackid": 35, "shelf_id": 174, "shelf_number": 400}	{"rackid": 35, "shelf_id": 174, "shelf_number": 3100}
558	shelf	UPDATE	175	2025-03-29 22:01:14.971228	{"rackid": 35, "shelf_id": 175, "shelf_number": 500}	{"rackid": 35, "shelf_id": 175, "shelf_number": 3200}
559	shelf	UPDATE	176	2025-03-29 22:01:14.971228	{"rackid": 36, "shelf_id": 176, "shelf_number": 100}	{"rackid": 36, "shelf_id": 176, "shelf_number": 2500}
560	shelf	UPDATE	177	2025-03-29 22:01:14.971228	{"rackid": 36, "shelf_id": 177, "shelf_number": 200}	{"rackid": 36, "shelf_id": 177, "shelf_number": 2600}
561	shelf	UPDATE	178	2025-03-29 22:01:14.971228	{"rackid": 36, "shelf_id": 178, "shelf_number": 300}	{"rackid": 36, "shelf_id": 178, "shelf_number": 2700}
562	shelf	UPDATE	179	2025-03-29 22:01:14.971228	{"rackid": 36, "shelf_id": 179, "shelf_number": 400}	{"rackid": 36, "shelf_id": 179, "shelf_number": 2800}
563	shelf	UPDATE	180	2025-03-29 22:01:14.971228	{"rackid": 36, "shelf_id": 180, "shelf_number": 500}	{"rackid": 36, "shelf_id": 180, "shelf_number": 2900}
564	shelf	UPDATE	181	2025-03-29 22:01:14.971228	{"rackid": 37, "shelf_id": 181, "shelf_number": 100}	{"rackid": 37, "shelf_id": 181, "shelf_number": 2600}
565	shelf	UPDATE	182	2025-03-29 22:01:14.971228	{"rackid": 37, "shelf_id": 182, "shelf_number": 200}	{"rackid": 37, "shelf_id": 182, "shelf_number": 2700}
566	shelf	UPDATE	183	2025-03-29 22:01:14.971228	{"rackid": 37, "shelf_id": 183, "shelf_number": 300}	{"rackid": 37, "shelf_id": 183, "shelf_number": 2800}
567	shelf	UPDATE	184	2025-03-29 22:01:14.971228	{"rackid": 37, "shelf_id": 184, "shelf_number": 400}	{"rackid": 37, "shelf_id": 184, "shelf_number": 2900}
568	shelf	UPDATE	185	2025-03-29 22:01:14.971228	{"rackid": 37, "shelf_id": 185, "shelf_number": 500}	{"rackid": 37, "shelf_id": 185, "shelf_number": 3000}
569	shelf	UPDATE	186	2025-03-29 22:01:14.971228	{"rackid": 38, "shelf_id": 186, "shelf_number": 100}	{"rackid": 38, "shelf_id": 186, "shelf_number": 2700}
570	shelf	UPDATE	187	2025-03-29 22:01:14.971228	{"rackid": 38, "shelf_id": 187, "shelf_number": 200}	{"rackid": 38, "shelf_id": 187, "shelf_number": 2800}
571	shelf	UPDATE	188	2025-03-29 22:01:14.971228	{"rackid": 38, "shelf_id": 188, "shelf_number": 300}	{"rackid": 38, "shelf_id": 188, "shelf_number": 2900}
572	shelf	UPDATE	189	2025-03-29 22:01:14.971228	{"rackid": 38, "shelf_id": 189, "shelf_number": 400}	{"rackid": 38, "shelf_id": 189, "shelf_number": 3000}
573	shelf	UPDATE	190	2025-03-29 22:01:14.971228	{"rackid": 38, "shelf_id": 190, "shelf_number": 500}	{"rackid": 38, "shelf_id": 190, "shelf_number": 3100}
574	shelf	UPDATE	191	2025-03-29 22:01:14.971228	{"rackid": 39, "shelf_id": 191, "shelf_number": 100}	{"rackid": 39, "shelf_id": 191, "shelf_number": 2800}
575	shelf	UPDATE	192	2025-03-29 22:01:14.971228	{"rackid": 39, "shelf_id": 192, "shelf_number": 200}	{"rackid": 39, "shelf_id": 192, "shelf_number": 2900}
576	shelf	UPDATE	193	2025-03-29 22:01:14.971228	{"rackid": 39, "shelf_id": 193, "shelf_number": 300}	{"rackid": 39, "shelf_id": 193, "shelf_number": 3000}
577	shelf	UPDATE	194	2025-03-29 22:01:14.971228	{"rackid": 39, "shelf_id": 194, "shelf_number": 400}	{"rackid": 39, "shelf_id": 194, "shelf_number": 3100}
578	shelf	UPDATE	195	2025-03-29 22:01:14.971228	{"rackid": 39, "shelf_id": 195, "shelf_number": 500}	{"rackid": 39, "shelf_id": 195, "shelf_number": 3200}
579	shelf	UPDATE	196	2025-03-29 22:01:14.971228	{"rackid": 40, "shelf_id": 196, "shelf_number": 100}	{"rackid": 40, "shelf_id": 196, "shelf_number": 2900}
580	shelf	UPDATE	197	2025-03-29 22:01:14.971228	{"rackid": 40, "shelf_id": 197, "shelf_number": 200}	{"rackid": 40, "shelf_id": 197, "shelf_number": 3000}
581	shelf	UPDATE	198	2025-03-29 22:01:14.971228	{"rackid": 40, "shelf_id": 198, "shelf_number": 300}	{"rackid": 40, "shelf_id": 198, "shelf_number": 3100}
582	shelf	UPDATE	199	2025-03-29 22:01:14.971228	{"rackid": 40, "shelf_id": 199, "shelf_number": 400}	{"rackid": 40, "shelf_id": 199, "shelf_number": 3200}
583	shelf	UPDATE	200	2025-03-29 22:01:14.971228	{"rackid": 40, "shelf_id": 200, "shelf_number": 500}	{"rackid": 40, "shelf_id": 200, "shelf_number": 3300}
584	shelf	UPDATE	201	2025-03-29 22:01:14.971228	{"rackid": 41, "shelf_id": 201, "shelf_number": 100}	{"rackid": 41, "shelf_id": 201, "shelf_number": 2600}
585	shelf	UPDATE	202	2025-03-29 22:01:14.971228	{"rackid": 41, "shelf_id": 202, "shelf_number": 200}	{"rackid": 41, "shelf_id": 202, "shelf_number": 2700}
586	shelf	UPDATE	203	2025-03-29 22:01:14.971228	{"rackid": 41, "shelf_id": 203, "shelf_number": 300}	{"rackid": 41, "shelf_id": 203, "shelf_number": 2800}
587	shelf	UPDATE	204	2025-03-29 22:01:14.971228	{"rackid": 41, "shelf_id": 204, "shelf_number": 400}	{"rackid": 41, "shelf_id": 204, "shelf_number": 2900}
588	shelf	UPDATE	205	2025-03-29 22:01:14.971228	{"rackid": 41, "shelf_id": 205, "shelf_number": 500}	{"rackid": 41, "shelf_id": 205, "shelf_number": 3000}
589	shelf	UPDATE	206	2025-03-29 22:01:14.971228	{"rackid": 42, "shelf_id": 206, "shelf_number": 100}	{"rackid": 42, "shelf_id": 206, "shelf_number": 2700}
590	shelf	UPDATE	207	2025-03-29 22:01:14.971228	{"rackid": 42, "shelf_id": 207, "shelf_number": 200}	{"rackid": 42, "shelf_id": 207, "shelf_number": 2800}
591	shelf	UPDATE	208	2025-03-29 22:01:14.971228	{"rackid": 42, "shelf_id": 208, "shelf_number": 300}	{"rackid": 42, "shelf_id": 208, "shelf_number": 2900}
592	shelf	UPDATE	209	2025-03-29 22:01:14.971228	{"rackid": 42, "shelf_id": 209, "shelf_number": 400}	{"rackid": 42, "shelf_id": 209, "shelf_number": 3000}
593	shelf	UPDATE	210	2025-03-29 22:01:14.971228	{"rackid": 42, "shelf_id": 210, "shelf_number": 500}	{"rackid": 42, "shelf_id": 210, "shelf_number": 3100}
594	shelf	UPDATE	211	2025-03-29 22:01:14.971228	{"rackid": 43, "shelf_id": 211, "shelf_number": 100}	{"rackid": 43, "shelf_id": 211, "shelf_number": 2800}
595	shelf	UPDATE	212	2025-03-29 22:01:14.971228	{"rackid": 43, "shelf_id": 212, "shelf_number": 200}	{"rackid": 43, "shelf_id": 212, "shelf_number": 2900}
596	shelf	UPDATE	213	2025-03-29 22:01:14.971228	{"rackid": 43, "shelf_id": 213, "shelf_number": 300}	{"rackid": 43, "shelf_id": 213, "shelf_number": 3000}
597	shelf	UPDATE	214	2025-03-29 22:01:14.971228	{"rackid": 43, "shelf_id": 214, "shelf_number": 400}	{"rackid": 43, "shelf_id": 214, "shelf_number": 3100}
598	shelf	UPDATE	215	2025-03-29 22:01:14.971228	{"rackid": 43, "shelf_id": 215, "shelf_number": 500}	{"rackid": 43, "shelf_id": 215, "shelf_number": 3200}
599	shelf	UPDATE	216	2025-03-29 22:01:14.971228	{"rackid": 44, "shelf_id": 216, "shelf_number": 100}	{"rackid": 44, "shelf_id": 216, "shelf_number": 2900}
600	shelf	UPDATE	217	2025-03-29 22:01:14.971228	{"rackid": 44, "shelf_id": 217, "shelf_number": 200}	{"rackid": 44, "shelf_id": 217, "shelf_number": 3000}
601	shelf	UPDATE	218	2025-03-29 22:01:14.971228	{"rackid": 44, "shelf_id": 218, "shelf_number": 300}	{"rackid": 44, "shelf_id": 218, "shelf_number": 3100}
602	shelf	UPDATE	219	2025-03-29 22:01:14.971228	{"rackid": 44, "shelf_id": 219, "shelf_number": 400}	{"rackid": 44, "shelf_id": 219, "shelf_number": 3200}
603	shelf	UPDATE	220	2025-03-29 22:01:14.971228	{"rackid": 44, "shelf_id": 220, "shelf_number": 500}	{"rackid": 44, "shelf_id": 220, "shelf_number": 3300}
604	shelf	UPDATE	221	2025-03-29 22:01:14.971228	{"rackid": 45, "shelf_id": 221, "shelf_number": 100}	{"rackid": 45, "shelf_id": 221, "shelf_number": 3000}
605	shelf	UPDATE	222	2025-03-29 22:01:14.971228	{"rackid": 45, "shelf_id": 222, "shelf_number": 200}	{"rackid": 45, "shelf_id": 222, "shelf_number": 3100}
606	shelf	UPDATE	223	2025-03-29 22:01:14.971228	{"rackid": 45, "shelf_id": 223, "shelf_number": 300}	{"rackid": 45, "shelf_id": 223, "shelf_number": 3200}
607	shelf	UPDATE	224	2025-03-29 22:01:14.971228	{"rackid": 45, "shelf_id": 224, "shelf_number": 400}	{"rackid": 45, "shelf_id": 224, "shelf_number": 3300}
608	shelf	UPDATE	225	2025-03-29 22:01:14.971228	{"rackid": 45, "shelf_id": 225, "shelf_number": 500}	{"rackid": 45, "shelf_id": 225, "shelf_number": 3400}
609	shelf	UPDATE	226	2025-03-29 22:01:14.971228	{"rackid": 46, "shelf_id": 226, "shelf_number": 100}	{"rackid": 46, "shelf_id": 226, "shelf_number": 2700}
610	shelf	UPDATE	227	2025-03-29 22:01:14.971228	{"rackid": 46, "shelf_id": 227, "shelf_number": 200}	{"rackid": 46, "shelf_id": 227, "shelf_number": 2800}
611	shelf	UPDATE	228	2025-03-29 22:01:14.971228	{"rackid": 46, "shelf_id": 228, "shelf_number": 300}	{"rackid": 46, "shelf_id": 228, "shelf_number": 2900}
612	shelf	UPDATE	229	2025-03-29 22:01:14.971228	{"rackid": 46, "shelf_id": 229, "shelf_number": 400}	{"rackid": 46, "shelf_id": 229, "shelf_number": 3000}
613	shelf	UPDATE	230	2025-03-29 22:01:14.971228	{"rackid": 46, "shelf_id": 230, "shelf_number": 500}	{"rackid": 46, "shelf_id": 230, "shelf_number": 3100}
614	shelf	UPDATE	231	2025-03-29 22:01:14.971228	{"rackid": 47, "shelf_id": 231, "shelf_number": 100}	{"rackid": 47, "shelf_id": 231, "shelf_number": 2800}
615	shelf	UPDATE	232	2025-03-29 22:01:14.971228	{"rackid": 47, "shelf_id": 232, "shelf_number": 200}	{"rackid": 47, "shelf_id": 232, "shelf_number": 2900}
616	shelf	UPDATE	233	2025-03-29 22:01:14.971228	{"rackid": 47, "shelf_id": 233, "shelf_number": 300}	{"rackid": 47, "shelf_id": 233, "shelf_number": 3000}
617	shelf	UPDATE	234	2025-03-29 22:01:14.971228	{"rackid": 47, "shelf_id": 234, "shelf_number": 400}	{"rackid": 47, "shelf_id": 234, "shelf_number": 3100}
618	shelf	UPDATE	235	2025-03-29 22:01:14.971228	{"rackid": 47, "shelf_id": 235, "shelf_number": 500}	{"rackid": 47, "shelf_id": 235, "shelf_number": 3200}
619	shelf	UPDATE	236	2025-03-29 22:01:14.971228	{"rackid": 48, "shelf_id": 236, "shelf_number": 100}	{"rackid": 48, "shelf_id": 236, "shelf_number": 2900}
620	shelf	UPDATE	237	2025-03-29 22:01:14.971228	{"rackid": 48, "shelf_id": 237, "shelf_number": 200}	{"rackid": 48, "shelf_id": 237, "shelf_number": 3000}
621	shelf	UPDATE	238	2025-03-29 22:01:14.971228	{"rackid": 48, "shelf_id": 238, "shelf_number": 300}	{"rackid": 48, "shelf_id": 238, "shelf_number": 3100}
622	shelf	UPDATE	239	2025-03-29 22:01:14.971228	{"rackid": 48, "shelf_id": 239, "shelf_number": 400}	{"rackid": 48, "shelf_id": 239, "shelf_number": 3200}
623	shelf	UPDATE	240	2025-03-29 22:01:14.971228	{"rackid": 48, "shelf_id": 240, "shelf_number": 500}	{"rackid": 48, "shelf_id": 240, "shelf_number": 3300}
624	shelf	UPDATE	241	2025-03-29 22:01:14.971228	{"rackid": 49, "shelf_id": 241, "shelf_number": 100}	{"rackid": 49, "shelf_id": 241, "shelf_number": 3000}
625	shelf	UPDATE	242	2025-03-29 22:01:14.971228	{"rackid": 49, "shelf_id": 242, "shelf_number": 200}	{"rackid": 49, "shelf_id": 242, "shelf_number": 3100}
626	shelf	UPDATE	243	2025-03-29 22:01:14.971228	{"rackid": 49, "shelf_id": 243, "shelf_number": 300}	{"rackid": 49, "shelf_id": 243, "shelf_number": 3200}
627	shelf	UPDATE	244	2025-03-29 22:01:14.971228	{"rackid": 49, "shelf_id": 244, "shelf_number": 400}	{"rackid": 49, "shelf_id": 244, "shelf_number": 3300}
628	shelf	UPDATE	245	2025-03-29 22:01:14.971228	{"rackid": 49, "shelf_id": 245, "shelf_number": 500}	{"rackid": 49, "shelf_id": 245, "shelf_number": 3400}
629	shelf	UPDATE	246	2025-03-29 22:01:14.971228	{"rackid": 50, "shelf_id": 246, "shelf_number": 100}	{"rackid": 50, "shelf_id": 246, "shelf_number": 3100}
630	shelf	UPDATE	247	2025-03-29 22:01:14.971228	{"rackid": 50, "shelf_id": 247, "shelf_number": 200}	{"rackid": 50, "shelf_id": 247, "shelf_number": 3200}
631	shelf	UPDATE	248	2025-03-29 22:01:14.971228	{"rackid": 50, "shelf_id": 248, "shelf_number": 300}	{"rackid": 50, "shelf_id": 248, "shelf_number": 3300}
632	shelf	UPDATE	249	2025-03-29 22:01:14.971228	{"rackid": 50, "shelf_id": 249, "shelf_number": 400}	{"rackid": 50, "shelf_id": 249, "shelf_number": 3400}
633	shelf	UPDATE	250	2025-03-29 22:01:14.971228	{"rackid": 50, "shelf_id": 250, "shelf_number": 500}	{"rackid": 50, "shelf_id": 250, "shelf_number": 3500}
634	shelf	UPDATE	251	2025-03-29 22:01:14.971228	{"rackid": 51, "shelf_id": 251, "shelf_number": 100}	{"rackid": 51, "shelf_id": 251, "shelf_number": 3300}
635	shelf	UPDATE	252	2025-03-29 22:01:14.971228	{"rackid": 51, "shelf_id": 252, "shelf_number": 200}	{"rackid": 51, "shelf_id": 252, "shelf_number": 3400}
636	shelf	UPDATE	253	2025-03-29 22:01:14.971228	{"rackid": 51, "shelf_id": 253, "shelf_number": 300}	{"rackid": 51, "shelf_id": 253, "shelf_number": 3500}
637	shelf	UPDATE	254	2025-03-29 22:01:14.971228	{"rackid": 51, "shelf_id": 254, "shelf_number": 400}	{"rackid": 51, "shelf_id": 254, "shelf_number": 3600}
638	shelf	UPDATE	255	2025-03-29 22:01:14.971228	{"rackid": 51, "shelf_id": 255, "shelf_number": 500}	{"rackid": 51, "shelf_id": 255, "shelf_number": 3700}
639	shelf	UPDATE	256	2025-03-29 22:01:14.971228	{"rackid": 52, "shelf_id": 256, "shelf_number": 100}	{"rackid": 52, "shelf_id": 256, "shelf_number": 3400}
640	shelf	UPDATE	257	2025-03-29 22:01:14.971228	{"rackid": 52, "shelf_id": 257, "shelf_number": 200}	{"rackid": 52, "shelf_id": 257, "shelf_number": 3500}
641	shelf	UPDATE	258	2025-03-29 22:01:14.971228	{"rackid": 52, "shelf_id": 258, "shelf_number": 300}	{"rackid": 52, "shelf_id": 258, "shelf_number": 3600}
642	shelf	UPDATE	259	2025-03-29 22:01:14.971228	{"rackid": 52, "shelf_id": 259, "shelf_number": 400}	{"rackid": 52, "shelf_id": 259, "shelf_number": 3700}
643	shelf	UPDATE	260	2025-03-29 22:01:14.971228	{"rackid": 52, "shelf_id": 260, "shelf_number": 500}	{"rackid": 52, "shelf_id": 260, "shelf_number": 3800}
644	shelf	UPDATE	261	2025-03-29 22:01:14.971228	{"rackid": 53, "shelf_id": 261, "shelf_number": 100}	{"rackid": 53, "shelf_id": 261, "shelf_number": 3500}
645	shelf	UPDATE	262	2025-03-29 22:01:14.971228	{"rackid": 53, "shelf_id": 262, "shelf_number": 200}	{"rackid": 53, "shelf_id": 262, "shelf_number": 3600}
646	shelf	UPDATE	263	2025-03-29 22:01:14.971228	{"rackid": 53, "shelf_id": 263, "shelf_number": 300}	{"rackid": 53, "shelf_id": 263, "shelf_number": 3700}
647	shelf	UPDATE	264	2025-03-29 22:01:14.971228	{"rackid": 53, "shelf_id": 264, "shelf_number": 400}	{"rackid": 53, "shelf_id": 264, "shelf_number": 3800}
648	shelf	UPDATE	265	2025-03-29 22:01:14.971228	{"rackid": 53, "shelf_id": 265, "shelf_number": 500}	{"rackid": 53, "shelf_id": 265, "shelf_number": 3900}
649	shelf	UPDATE	266	2025-03-29 22:01:14.971228	{"rackid": 54, "shelf_id": 266, "shelf_number": 100}	{"rackid": 54, "shelf_id": 266, "shelf_number": 3600}
650	shelf	UPDATE	267	2025-03-29 22:01:14.971228	{"rackid": 54, "shelf_id": 267, "shelf_number": 200}	{"rackid": 54, "shelf_id": 267, "shelf_number": 3700}
651	shelf	UPDATE	268	2025-03-29 22:01:14.971228	{"rackid": 54, "shelf_id": 268, "shelf_number": 300}	{"rackid": 54, "shelf_id": 268, "shelf_number": 3800}
652	shelf	UPDATE	269	2025-03-29 22:01:14.971228	{"rackid": 54, "shelf_id": 269, "shelf_number": 400}	{"rackid": 54, "shelf_id": 269, "shelf_number": 3900}
653	shelf	UPDATE	270	2025-03-29 22:01:14.971228	{"rackid": 54, "shelf_id": 270, "shelf_number": 500}	{"rackid": 54, "shelf_id": 270, "shelf_number": 4000}
654	shelf	UPDATE	271	2025-03-29 22:01:14.971228	{"rackid": 55, "shelf_id": 271, "shelf_number": 100}	{"rackid": 55, "shelf_id": 271, "shelf_number": 3700}
655	shelf	UPDATE	272	2025-03-29 22:01:14.971228	{"rackid": 55, "shelf_id": 272, "shelf_number": 200}	{"rackid": 55, "shelf_id": 272, "shelf_number": 3800}
656	shelf	UPDATE	273	2025-03-29 22:01:14.971228	{"rackid": 55, "shelf_id": 273, "shelf_number": 300}	{"rackid": 55, "shelf_id": 273, "shelf_number": 3900}
657	shelf	UPDATE	274	2025-03-29 22:01:14.971228	{"rackid": 55, "shelf_id": 274, "shelf_number": 400}	{"rackid": 55, "shelf_id": 274, "shelf_number": 4000}
658	shelf	UPDATE	275	2025-03-29 22:01:14.971228	{"rackid": 55, "shelf_id": 275, "shelf_number": 500}	{"rackid": 55, "shelf_id": 275, "shelf_number": 4100}
659	shelf	UPDATE	276	2025-03-29 22:01:14.971228	{"rackid": 56, "shelf_id": 276, "shelf_number": 100}	{"rackid": 56, "shelf_id": 276, "shelf_number": 3400}
660	shelf	UPDATE	277	2025-03-29 22:01:14.971228	{"rackid": 56, "shelf_id": 277, "shelf_number": 200}	{"rackid": 56, "shelf_id": 277, "shelf_number": 3500}
661	shelf	UPDATE	278	2025-03-29 22:01:14.971228	{"rackid": 56, "shelf_id": 278, "shelf_number": 300}	{"rackid": 56, "shelf_id": 278, "shelf_number": 3600}
662	shelf	UPDATE	279	2025-03-29 22:01:14.971228	{"rackid": 56, "shelf_id": 279, "shelf_number": 400}	{"rackid": 56, "shelf_id": 279, "shelf_number": 3700}
663	shelf	UPDATE	280	2025-03-29 22:01:14.971228	{"rackid": 56, "shelf_id": 280, "shelf_number": 500}	{"rackid": 56, "shelf_id": 280, "shelf_number": 3800}
664	shelf	UPDATE	281	2025-03-29 22:01:14.971228	{"rackid": 57, "shelf_id": 281, "shelf_number": 100}	{"rackid": 57, "shelf_id": 281, "shelf_number": 3500}
665	shelf	UPDATE	282	2025-03-29 22:01:14.971228	{"rackid": 57, "shelf_id": 282, "shelf_number": 200}	{"rackid": 57, "shelf_id": 282, "shelf_number": 3600}
666	shelf	UPDATE	283	2025-03-29 22:01:14.971228	{"rackid": 57, "shelf_id": 283, "shelf_number": 300}	{"rackid": 57, "shelf_id": 283, "shelf_number": 3700}
667	shelf	UPDATE	284	2025-03-29 22:01:14.971228	{"rackid": 57, "shelf_id": 284, "shelf_number": 400}	{"rackid": 57, "shelf_id": 284, "shelf_number": 3800}
668	shelf	UPDATE	285	2025-03-29 22:01:14.971228	{"rackid": 57, "shelf_id": 285, "shelf_number": 500}	{"rackid": 57, "shelf_id": 285, "shelf_number": 3900}
669	shelf	UPDATE	286	2025-03-29 22:01:14.971228	{"rackid": 58, "shelf_id": 286, "shelf_number": 100}	{"rackid": 58, "shelf_id": 286, "shelf_number": 3600}
670	shelf	UPDATE	287	2025-03-29 22:01:14.971228	{"rackid": 58, "shelf_id": 287, "shelf_number": 200}	{"rackid": 58, "shelf_id": 287, "shelf_number": 3700}
671	shelf	UPDATE	288	2025-03-29 22:01:14.971228	{"rackid": 58, "shelf_id": 288, "shelf_number": 300}	{"rackid": 58, "shelf_id": 288, "shelf_number": 3800}
672	shelf	UPDATE	289	2025-03-29 22:01:14.971228	{"rackid": 58, "shelf_id": 289, "shelf_number": 400}	{"rackid": 58, "shelf_id": 289, "shelf_number": 3900}
673	shelf	UPDATE	290	2025-03-29 22:01:14.971228	{"rackid": 58, "shelf_id": 290, "shelf_number": 500}	{"rackid": 58, "shelf_id": 290, "shelf_number": 4000}
674	shelf	UPDATE	291	2025-03-29 22:01:14.971228	{"rackid": 59, "shelf_id": 291, "shelf_number": 100}	{"rackid": 59, "shelf_id": 291, "shelf_number": 3700}
675	shelf	UPDATE	292	2025-03-29 22:01:14.971228	{"rackid": 59, "shelf_id": 292, "shelf_number": 200}	{"rackid": 59, "shelf_id": 292, "shelf_number": 3800}
676	shelf	UPDATE	293	2025-03-29 22:01:14.971228	{"rackid": 59, "shelf_id": 293, "shelf_number": 300}	{"rackid": 59, "shelf_id": 293, "shelf_number": 3900}
677	shelf	UPDATE	294	2025-03-29 22:01:14.971228	{"rackid": 59, "shelf_id": 294, "shelf_number": 400}	{"rackid": 59, "shelf_id": 294, "shelf_number": 4000}
678	shelf	UPDATE	295	2025-03-29 22:01:14.971228	{"rackid": 59, "shelf_id": 295, "shelf_number": 500}	{"rackid": 59, "shelf_id": 295, "shelf_number": 4100}
679	shelf	UPDATE	296	2025-03-29 22:01:14.971228	{"rackid": 60, "shelf_id": 296, "shelf_number": 100}	{"rackid": 60, "shelf_id": 296, "shelf_number": 3800}
680	shelf	UPDATE	297	2025-03-29 22:01:14.971228	{"rackid": 60, "shelf_id": 297, "shelf_number": 200}	{"rackid": 60, "shelf_id": 297, "shelf_number": 3900}
681	shelf	UPDATE	298	2025-03-29 22:01:14.971228	{"rackid": 60, "shelf_id": 298, "shelf_number": 300}	{"rackid": 60, "shelf_id": 298, "shelf_number": 4000}
682	shelf	UPDATE	299	2025-03-29 22:01:14.971228	{"rackid": 60, "shelf_id": 299, "shelf_number": 400}	{"rackid": 60, "shelf_id": 299, "shelf_number": 4100}
683	shelf	UPDATE	300	2025-03-29 22:01:14.971228	{"rackid": 60, "shelf_id": 300, "shelf_number": 500}	{"rackid": 60, "shelf_id": 300, "shelf_number": 4200}
684	shelf	UPDATE	301	2025-03-29 22:01:14.971228	{"rackid": 61, "shelf_id": 301, "shelf_number": 100}	{"rackid": 61, "shelf_id": 301, "shelf_number": 3500}
685	shelf	UPDATE	302	2025-03-29 22:01:14.971228	{"rackid": 61, "shelf_id": 302, "shelf_number": 200}	{"rackid": 61, "shelf_id": 302, "shelf_number": 3600}
686	shelf	UPDATE	303	2025-03-29 22:01:14.971228	{"rackid": 61, "shelf_id": 303, "shelf_number": 300}	{"rackid": 61, "shelf_id": 303, "shelf_number": 3700}
687	shelf	UPDATE	304	2025-03-29 22:01:14.971228	{"rackid": 61, "shelf_id": 304, "shelf_number": 400}	{"rackid": 61, "shelf_id": 304, "shelf_number": 3800}
688	shelf	UPDATE	305	2025-03-29 22:01:14.971228	{"rackid": 61, "shelf_id": 305, "shelf_number": 500}	{"rackid": 61, "shelf_id": 305, "shelf_number": 3900}
689	shelf	UPDATE	306	2025-03-29 22:01:14.971228	{"rackid": 62, "shelf_id": 306, "shelf_number": 100}	{"rackid": 62, "shelf_id": 306, "shelf_number": 3600}
690	shelf	UPDATE	307	2025-03-29 22:01:14.971228	{"rackid": 62, "shelf_id": 307, "shelf_number": 200}	{"rackid": 62, "shelf_id": 307, "shelf_number": 3700}
691	shelf	UPDATE	308	2025-03-29 22:01:14.971228	{"rackid": 62, "shelf_id": 308, "shelf_number": 300}	{"rackid": 62, "shelf_id": 308, "shelf_number": 3800}
692	shelf	UPDATE	309	2025-03-29 22:01:14.971228	{"rackid": 62, "shelf_id": 309, "shelf_number": 400}	{"rackid": 62, "shelf_id": 309, "shelf_number": 3900}
693	shelf	UPDATE	310	2025-03-29 22:01:14.971228	{"rackid": 62, "shelf_id": 310, "shelf_number": 500}	{"rackid": 62, "shelf_id": 310, "shelf_number": 4000}
694	shelf	UPDATE	311	2025-03-29 22:01:14.971228	{"rackid": 63, "shelf_id": 311, "shelf_number": 100}	{"rackid": 63, "shelf_id": 311, "shelf_number": 3700}
695	shelf	UPDATE	312	2025-03-29 22:01:14.971228	{"rackid": 63, "shelf_id": 312, "shelf_number": 200}	{"rackid": 63, "shelf_id": 312, "shelf_number": 3800}
696	shelf	UPDATE	313	2025-03-29 22:01:14.971228	{"rackid": 63, "shelf_id": 313, "shelf_number": 300}	{"rackid": 63, "shelf_id": 313, "shelf_number": 3900}
697	shelf	UPDATE	314	2025-03-29 22:01:14.971228	{"rackid": 63, "shelf_id": 314, "shelf_number": 400}	{"rackid": 63, "shelf_id": 314, "shelf_number": 4000}
698	shelf	UPDATE	315	2025-03-29 22:01:14.971228	{"rackid": 63, "shelf_id": 315, "shelf_number": 500}	{"rackid": 63, "shelf_id": 315, "shelf_number": 4100}
699	shelf	UPDATE	316	2025-03-29 22:01:14.971228	{"rackid": 64, "shelf_id": 316, "shelf_number": 100}	{"rackid": 64, "shelf_id": 316, "shelf_number": 3800}
700	shelf	UPDATE	317	2025-03-29 22:01:14.971228	{"rackid": 64, "shelf_id": 317, "shelf_number": 200}	{"rackid": 64, "shelf_id": 317, "shelf_number": 3900}
701	shelf	UPDATE	318	2025-03-29 22:01:14.971228	{"rackid": 64, "shelf_id": 318, "shelf_number": 300}	{"rackid": 64, "shelf_id": 318, "shelf_number": 4000}
702	shelf	UPDATE	319	2025-03-29 22:01:14.971228	{"rackid": 64, "shelf_id": 319, "shelf_number": 400}	{"rackid": 64, "shelf_id": 319, "shelf_number": 4100}
703	shelf	UPDATE	320	2025-03-29 22:01:14.971228	{"rackid": 64, "shelf_id": 320, "shelf_number": 500}	{"rackid": 64, "shelf_id": 320, "shelf_number": 4200}
704	shelf	UPDATE	321	2025-03-29 22:01:14.971228	{"rackid": 65, "shelf_id": 321, "shelf_number": 100}	{"rackid": 65, "shelf_id": 321, "shelf_number": 3900}
705	shelf	UPDATE	322	2025-03-29 22:01:14.971228	{"rackid": 65, "shelf_id": 322, "shelf_number": 200}	{"rackid": 65, "shelf_id": 322, "shelf_number": 4000}
706	shelf	UPDATE	323	2025-03-29 22:01:14.971228	{"rackid": 65, "shelf_id": 323, "shelf_number": 300}	{"rackid": 65, "shelf_id": 323, "shelf_number": 4100}
707	shelf	UPDATE	324	2025-03-29 22:01:14.971228	{"rackid": 65, "shelf_id": 324, "shelf_number": 400}	{"rackid": 65, "shelf_id": 324, "shelf_number": 4200}
708	shelf	UPDATE	325	2025-03-29 22:01:14.971228	{"rackid": 65, "shelf_id": 325, "shelf_number": 500}	{"rackid": 65, "shelf_id": 325, "shelf_number": 4300}
709	shelf	UPDATE	326	2025-03-29 22:01:14.971228	{"rackid": 66, "shelf_id": 326, "shelf_number": 100}	{"rackid": 66, "shelf_id": 326, "shelf_number": 3600}
710	shelf	UPDATE	327	2025-03-29 22:01:14.971228	{"rackid": 66, "shelf_id": 327, "shelf_number": 200}	{"rackid": 66, "shelf_id": 327, "shelf_number": 3700}
711	shelf	UPDATE	328	2025-03-29 22:01:14.971228	{"rackid": 66, "shelf_id": 328, "shelf_number": 300}	{"rackid": 66, "shelf_id": 328, "shelf_number": 3800}
712	shelf	UPDATE	329	2025-03-29 22:01:14.971228	{"rackid": 66, "shelf_id": 329, "shelf_number": 400}	{"rackid": 66, "shelf_id": 329, "shelf_number": 3900}
713	shelf	UPDATE	330	2025-03-29 22:01:14.971228	{"rackid": 66, "shelf_id": 330, "shelf_number": 500}	{"rackid": 66, "shelf_id": 330, "shelf_number": 4000}
714	shelf	UPDATE	331	2025-03-29 22:01:14.971228	{"rackid": 67, "shelf_id": 331, "shelf_number": 100}	{"rackid": 67, "shelf_id": 331, "shelf_number": 3700}
715	shelf	UPDATE	332	2025-03-29 22:01:14.971228	{"rackid": 67, "shelf_id": 332, "shelf_number": 200}	{"rackid": 67, "shelf_id": 332, "shelf_number": 3800}
716	shelf	UPDATE	333	2025-03-29 22:01:14.971228	{"rackid": 67, "shelf_id": 333, "shelf_number": 300}	{"rackid": 67, "shelf_id": 333, "shelf_number": 3900}
717	shelf	UPDATE	334	2025-03-29 22:01:14.971228	{"rackid": 67, "shelf_id": 334, "shelf_number": 400}	{"rackid": 67, "shelf_id": 334, "shelf_number": 4000}
718	shelf	UPDATE	335	2025-03-29 22:01:14.971228	{"rackid": 67, "shelf_id": 335, "shelf_number": 500}	{"rackid": 67, "shelf_id": 335, "shelf_number": 4100}
719	shelf	UPDATE	336	2025-03-29 22:01:14.971228	{"rackid": 68, "shelf_id": 336, "shelf_number": 100}	{"rackid": 68, "shelf_id": 336, "shelf_number": 3800}
720	shelf	UPDATE	337	2025-03-29 22:01:14.971228	{"rackid": 68, "shelf_id": 337, "shelf_number": 200}	{"rackid": 68, "shelf_id": 337, "shelf_number": 3900}
721	shelf	UPDATE	338	2025-03-29 22:01:14.971228	{"rackid": 68, "shelf_id": 338, "shelf_number": 300}	{"rackid": 68, "shelf_id": 338, "shelf_number": 4000}
722	shelf	UPDATE	339	2025-03-29 22:01:14.971228	{"rackid": 68, "shelf_id": 339, "shelf_number": 400}	{"rackid": 68, "shelf_id": 339, "shelf_number": 4100}
723	shelf	UPDATE	340	2025-03-29 22:01:14.971228	{"rackid": 68, "shelf_id": 340, "shelf_number": 500}	{"rackid": 68, "shelf_id": 340, "shelf_number": 4200}
724	shelf	UPDATE	341	2025-03-29 22:01:14.971228	{"rackid": 69, "shelf_id": 341, "shelf_number": 100}	{"rackid": 69, "shelf_id": 341, "shelf_number": 3900}
725	shelf	UPDATE	342	2025-03-29 22:01:14.971228	{"rackid": 69, "shelf_id": 342, "shelf_number": 200}	{"rackid": 69, "shelf_id": 342, "shelf_number": 4000}
726	shelf	UPDATE	343	2025-03-29 22:01:14.971228	{"rackid": 69, "shelf_id": 343, "shelf_number": 300}	{"rackid": 69, "shelf_id": 343, "shelf_number": 4100}
727	shelf	UPDATE	344	2025-03-29 22:01:14.971228	{"rackid": 69, "shelf_id": 344, "shelf_number": 400}	{"rackid": 69, "shelf_id": 344, "shelf_number": 4200}
728	shelf	UPDATE	345	2025-03-29 22:01:14.971228	{"rackid": 69, "shelf_id": 345, "shelf_number": 500}	{"rackid": 69, "shelf_id": 345, "shelf_number": 4300}
729	shelf	UPDATE	346	2025-03-29 22:01:14.971228	{"rackid": 70, "shelf_id": 346, "shelf_number": 100}	{"rackid": 70, "shelf_id": 346, "shelf_number": 4000}
730	shelf	UPDATE	347	2025-03-29 22:01:14.971228	{"rackid": 70, "shelf_id": 347, "shelf_number": 200}	{"rackid": 70, "shelf_id": 347, "shelf_number": 4100}
731	shelf	UPDATE	348	2025-03-29 22:01:14.971228	{"rackid": 70, "shelf_id": 348, "shelf_number": 300}	{"rackid": 70, "shelf_id": 348, "shelf_number": 4200}
732	shelf	UPDATE	349	2025-03-29 22:01:14.971228	{"rackid": 70, "shelf_id": 349, "shelf_number": 400}	{"rackid": 70, "shelf_id": 349, "shelf_number": 4300}
733	shelf	UPDATE	350	2025-03-29 22:01:14.971228	{"rackid": 70, "shelf_id": 350, "shelf_number": 500}	{"rackid": 70, "shelf_id": 350, "shelf_number": 4400}
734	shelf	UPDATE	351	2025-03-29 22:01:14.971228	{"rackid": 71, "shelf_id": 351, "shelf_number": 100}	{"rackid": 71, "shelf_id": 351, "shelf_number": 3700}
735	shelf	UPDATE	352	2025-03-29 22:01:14.971228	{"rackid": 71, "shelf_id": 352, "shelf_number": 200}	{"rackid": 71, "shelf_id": 352, "shelf_number": 3800}
736	shelf	UPDATE	353	2025-03-29 22:01:14.971228	{"rackid": 71, "shelf_id": 353, "shelf_number": 300}	{"rackid": 71, "shelf_id": 353, "shelf_number": 3900}
737	shelf	UPDATE	354	2025-03-29 22:01:14.971228	{"rackid": 71, "shelf_id": 354, "shelf_number": 400}	{"rackid": 71, "shelf_id": 354, "shelf_number": 4000}
738	shelf	UPDATE	355	2025-03-29 22:01:14.971228	{"rackid": 71, "shelf_id": 355, "shelf_number": 500}	{"rackid": 71, "shelf_id": 355, "shelf_number": 4100}
739	shelf	UPDATE	356	2025-03-29 22:01:14.971228	{"rackid": 72, "shelf_id": 356, "shelf_number": 100}	{"rackid": 72, "shelf_id": 356, "shelf_number": 3800}
740	shelf	UPDATE	357	2025-03-29 22:01:14.971228	{"rackid": 72, "shelf_id": 357, "shelf_number": 200}	{"rackid": 72, "shelf_id": 357, "shelf_number": 3900}
741	shelf	UPDATE	358	2025-03-29 22:01:14.971228	{"rackid": 72, "shelf_id": 358, "shelf_number": 300}	{"rackid": 72, "shelf_id": 358, "shelf_number": 4000}
742	shelf	UPDATE	359	2025-03-29 22:01:14.971228	{"rackid": 72, "shelf_id": 359, "shelf_number": 400}	{"rackid": 72, "shelf_id": 359, "shelf_number": 4100}
743	shelf	UPDATE	360	2025-03-29 22:01:14.971228	{"rackid": 72, "shelf_id": 360, "shelf_number": 500}	{"rackid": 72, "shelf_id": 360, "shelf_number": 4200}
744	shelf	UPDATE	361	2025-03-29 22:01:14.971228	{"rackid": 73, "shelf_id": 361, "shelf_number": 100}	{"rackid": 73, "shelf_id": 361, "shelf_number": 3900}
745	shelf	UPDATE	362	2025-03-29 22:01:14.971228	{"rackid": 73, "shelf_id": 362, "shelf_number": 200}	{"rackid": 73, "shelf_id": 362, "shelf_number": 4000}
746	shelf	UPDATE	363	2025-03-29 22:01:14.971228	{"rackid": 73, "shelf_id": 363, "shelf_number": 300}	{"rackid": 73, "shelf_id": 363, "shelf_number": 4100}
747	shelf	UPDATE	364	2025-03-29 22:01:14.971228	{"rackid": 73, "shelf_id": 364, "shelf_number": 400}	{"rackid": 73, "shelf_id": 364, "shelf_number": 4200}
748	shelf	UPDATE	365	2025-03-29 22:01:14.971228	{"rackid": 73, "shelf_id": 365, "shelf_number": 500}	{"rackid": 73, "shelf_id": 365, "shelf_number": 4300}
749	shelf	UPDATE	366	2025-03-29 22:01:14.971228	{"rackid": 74, "shelf_id": 366, "shelf_number": 100}	{"rackid": 74, "shelf_id": 366, "shelf_number": 4000}
750	shelf	UPDATE	367	2025-03-29 22:01:14.971228	{"rackid": 74, "shelf_id": 367, "shelf_number": 200}	{"rackid": 74, "shelf_id": 367, "shelf_number": 4100}
751	shelf	UPDATE	368	2025-03-29 22:01:14.971228	{"rackid": 74, "shelf_id": 368, "shelf_number": 300}	{"rackid": 74, "shelf_id": 368, "shelf_number": 4200}
752	shelf	UPDATE	369	2025-03-29 22:01:14.971228	{"rackid": 74, "shelf_id": 369, "shelf_number": 400}	{"rackid": 74, "shelf_id": 369, "shelf_number": 4300}
753	shelf	UPDATE	370	2025-03-29 22:01:14.971228	{"rackid": 74, "shelf_id": 370, "shelf_number": 500}	{"rackid": 74, "shelf_id": 370, "shelf_number": 4400}
754	shelf	UPDATE	371	2025-03-29 22:01:14.971228	{"rackid": 75, "shelf_id": 371, "shelf_number": 100}	{"rackid": 75, "shelf_id": 371, "shelf_number": 4100}
755	shelf	UPDATE	372	2025-03-29 22:01:14.971228	{"rackid": 75, "shelf_id": 372, "shelf_number": 200}	{"rackid": 75, "shelf_id": 372, "shelf_number": 4200}
756	shelf	UPDATE	373	2025-03-29 22:01:14.971228	{"rackid": 75, "shelf_id": 373, "shelf_number": 300}	{"rackid": 75, "shelf_id": 373, "shelf_number": 4300}
757	shelf	UPDATE	374	2025-03-29 22:01:14.971228	{"rackid": 75, "shelf_id": 374, "shelf_number": 400}	{"rackid": 75, "shelf_id": 374, "shelf_number": 4400}
758	shelf	UPDATE	375	2025-03-29 22:01:14.971228	{"rackid": 75, "shelf_id": 375, "shelf_number": 500}	{"rackid": 75, "shelf_id": 375, "shelf_number": 4500}
759	shelf	UPDATE	376	2025-03-29 22:01:14.971228	{"rackid": 76, "shelf_id": 376, "shelf_number": 100}	{"rackid": 76, "shelf_id": 376, "shelf_number": 4300}
760	shelf	UPDATE	377	2025-03-29 22:01:14.971228	{"rackid": 76, "shelf_id": 377, "shelf_number": 200}	{"rackid": 76, "shelf_id": 377, "shelf_number": 4400}
761	shelf	UPDATE	378	2025-03-29 22:01:14.971228	{"rackid": 76, "shelf_id": 378, "shelf_number": 300}	{"rackid": 76, "shelf_id": 378, "shelf_number": 4500}
762	shelf	UPDATE	379	2025-03-29 22:01:14.971228	{"rackid": 76, "shelf_id": 379, "shelf_number": 400}	{"rackid": 76, "shelf_id": 379, "shelf_number": 4600}
763	shelf	UPDATE	380	2025-03-29 22:01:14.971228	{"rackid": 76, "shelf_id": 380, "shelf_number": 500}	{"rackid": 76, "shelf_id": 380, "shelf_number": 4700}
764	shelf	UPDATE	381	2025-03-29 22:01:14.971228	{"rackid": 77, "shelf_id": 381, "shelf_number": 100}	{"rackid": 77, "shelf_id": 381, "shelf_number": 4400}
765	shelf	UPDATE	382	2025-03-29 22:01:14.971228	{"rackid": 77, "shelf_id": 382, "shelf_number": 200}	{"rackid": 77, "shelf_id": 382, "shelf_number": 4500}
766	shelf	UPDATE	383	2025-03-29 22:01:14.971228	{"rackid": 77, "shelf_id": 383, "shelf_number": 300}	{"rackid": 77, "shelf_id": 383, "shelf_number": 4600}
767	shelf	UPDATE	384	2025-03-29 22:01:14.971228	{"rackid": 77, "shelf_id": 384, "shelf_number": 400}	{"rackid": 77, "shelf_id": 384, "shelf_number": 4700}
768	shelf	UPDATE	385	2025-03-29 22:01:14.971228	{"rackid": 77, "shelf_id": 385, "shelf_number": 500}	{"rackid": 77, "shelf_id": 385, "shelf_number": 4800}
769	shelf	UPDATE	386	2025-03-29 22:01:14.971228	{"rackid": 78, "shelf_id": 386, "shelf_number": 100}	{"rackid": 78, "shelf_id": 386, "shelf_number": 4500}
770	shelf	UPDATE	387	2025-03-29 22:01:14.971228	{"rackid": 78, "shelf_id": 387, "shelf_number": 200}	{"rackid": 78, "shelf_id": 387, "shelf_number": 4600}
771	shelf	UPDATE	388	2025-03-29 22:01:14.971228	{"rackid": 78, "shelf_id": 388, "shelf_number": 300}	{"rackid": 78, "shelf_id": 388, "shelf_number": 4700}
772	shelf	UPDATE	389	2025-03-29 22:01:14.971228	{"rackid": 78, "shelf_id": 389, "shelf_number": 400}	{"rackid": 78, "shelf_id": 389, "shelf_number": 4800}
773	shelf	UPDATE	390	2025-03-29 22:01:14.971228	{"rackid": 78, "shelf_id": 390, "shelf_number": 500}	{"rackid": 78, "shelf_id": 390, "shelf_number": 4900}
774	shelf	UPDATE	391	2025-03-29 22:01:14.971228	{"rackid": 79, "shelf_id": 391, "shelf_number": 100}	{"rackid": 79, "shelf_id": 391, "shelf_number": 4600}
775	shelf	UPDATE	392	2025-03-29 22:01:14.971228	{"rackid": 79, "shelf_id": 392, "shelf_number": 200}	{"rackid": 79, "shelf_id": 392, "shelf_number": 4700}
776	shelf	UPDATE	393	2025-03-29 22:01:14.971228	{"rackid": 79, "shelf_id": 393, "shelf_number": 300}	{"rackid": 79, "shelf_id": 393, "shelf_number": 4800}
777	shelf	UPDATE	394	2025-03-29 22:01:14.971228	{"rackid": 79, "shelf_id": 394, "shelf_number": 400}	{"rackid": 79, "shelf_id": 394, "shelf_number": 4900}
778	shelf	UPDATE	395	2025-03-29 22:01:14.971228	{"rackid": 79, "shelf_id": 395, "shelf_number": 500}	{"rackid": 79, "shelf_id": 395, "shelf_number": 5000}
779	shelf	UPDATE	396	2025-03-29 22:01:14.971228	{"rackid": 80, "shelf_id": 396, "shelf_number": 100}	{"rackid": 80, "shelf_id": 396, "shelf_number": 4700}
780	shelf	UPDATE	397	2025-03-29 22:01:14.971228	{"rackid": 80, "shelf_id": 397, "shelf_number": 200}	{"rackid": 80, "shelf_id": 397, "shelf_number": 4800}
781	shelf	UPDATE	398	2025-03-29 22:01:14.971228	{"rackid": 80, "shelf_id": 398, "shelf_number": 300}	{"rackid": 80, "shelf_id": 398, "shelf_number": 4900}
782	shelf	UPDATE	399	2025-03-29 22:01:14.971228	{"rackid": 80, "shelf_id": 399, "shelf_number": 400}	{"rackid": 80, "shelf_id": 399, "shelf_number": 5000}
783	shelf	UPDATE	400	2025-03-29 22:01:14.971228	{"rackid": 80, "shelf_id": 400, "shelf_number": 500}	{"rackid": 80, "shelf_id": 400, "shelf_number": 5100}
784	shelf	UPDATE	401	2025-03-29 22:01:14.971228	{"rackid": 81, "shelf_id": 401, "shelf_number": 100}	{"rackid": 81, "shelf_id": 401, "shelf_number": 4400}
785	shelf	UPDATE	402	2025-03-29 22:01:14.971228	{"rackid": 81, "shelf_id": 402, "shelf_number": 200}	{"rackid": 81, "shelf_id": 402, "shelf_number": 4500}
786	shelf	UPDATE	403	2025-03-29 22:01:14.971228	{"rackid": 81, "shelf_id": 403, "shelf_number": 300}	{"rackid": 81, "shelf_id": 403, "shelf_number": 4600}
787	shelf	UPDATE	404	2025-03-29 22:01:14.971228	{"rackid": 81, "shelf_id": 404, "shelf_number": 400}	{"rackid": 81, "shelf_id": 404, "shelf_number": 4700}
788	shelf	UPDATE	405	2025-03-29 22:01:14.971228	{"rackid": 81, "shelf_id": 405, "shelf_number": 500}	{"rackid": 81, "shelf_id": 405, "shelf_number": 4800}
789	shelf	UPDATE	406	2025-03-29 22:01:14.971228	{"rackid": 82, "shelf_id": 406, "shelf_number": 100}	{"rackid": 82, "shelf_id": 406, "shelf_number": 4500}
790	shelf	UPDATE	407	2025-03-29 22:01:14.971228	{"rackid": 82, "shelf_id": 407, "shelf_number": 200}	{"rackid": 82, "shelf_id": 407, "shelf_number": 4600}
791	shelf	UPDATE	408	2025-03-29 22:01:14.971228	{"rackid": 82, "shelf_id": 408, "shelf_number": 300}	{"rackid": 82, "shelf_id": 408, "shelf_number": 4700}
792	shelf	UPDATE	409	2025-03-29 22:01:14.971228	{"rackid": 82, "shelf_id": 409, "shelf_number": 400}	{"rackid": 82, "shelf_id": 409, "shelf_number": 4800}
793	shelf	UPDATE	410	2025-03-29 22:01:14.971228	{"rackid": 82, "shelf_id": 410, "shelf_number": 500}	{"rackid": 82, "shelf_id": 410, "shelf_number": 4900}
794	shelf	UPDATE	411	2025-03-29 22:01:14.971228	{"rackid": 83, "shelf_id": 411, "shelf_number": 100}	{"rackid": 83, "shelf_id": 411, "shelf_number": 4600}
795	shelf	UPDATE	412	2025-03-29 22:01:14.971228	{"rackid": 83, "shelf_id": 412, "shelf_number": 200}	{"rackid": 83, "shelf_id": 412, "shelf_number": 4700}
796	shelf	UPDATE	413	2025-03-29 22:01:14.971228	{"rackid": 83, "shelf_id": 413, "shelf_number": 300}	{"rackid": 83, "shelf_id": 413, "shelf_number": 4800}
797	shelf	UPDATE	414	2025-03-29 22:01:14.971228	{"rackid": 83, "shelf_id": 414, "shelf_number": 400}	{"rackid": 83, "shelf_id": 414, "shelf_number": 4900}
798	shelf	UPDATE	415	2025-03-29 22:01:14.971228	{"rackid": 83, "shelf_id": 415, "shelf_number": 500}	{"rackid": 83, "shelf_id": 415, "shelf_number": 5000}
799	shelf	UPDATE	416	2025-03-29 22:01:14.971228	{"rackid": 84, "shelf_id": 416, "shelf_number": 100}	{"rackid": 84, "shelf_id": 416, "shelf_number": 4700}
800	shelf	UPDATE	417	2025-03-29 22:01:14.971228	{"rackid": 84, "shelf_id": 417, "shelf_number": 200}	{"rackid": 84, "shelf_id": 417, "shelf_number": 4800}
801	shelf	UPDATE	418	2025-03-29 22:01:14.971228	{"rackid": 84, "shelf_id": 418, "shelf_number": 300}	{"rackid": 84, "shelf_id": 418, "shelf_number": 4900}
802	shelf	UPDATE	419	2025-03-29 22:01:14.971228	{"rackid": 84, "shelf_id": 419, "shelf_number": 400}	{"rackid": 84, "shelf_id": 419, "shelf_number": 5000}
803	shelf	UPDATE	420	2025-03-29 22:01:14.971228	{"rackid": 84, "shelf_id": 420, "shelf_number": 500}	{"rackid": 84, "shelf_id": 420, "shelf_number": 5100}
804	shelf	UPDATE	421	2025-03-29 22:01:14.971228	{"rackid": 85, "shelf_id": 421, "shelf_number": 100}	{"rackid": 85, "shelf_id": 421, "shelf_number": 4800}
805	shelf	UPDATE	422	2025-03-29 22:01:14.971228	{"rackid": 85, "shelf_id": 422, "shelf_number": 200}	{"rackid": 85, "shelf_id": 422, "shelf_number": 4900}
806	shelf	UPDATE	423	2025-03-29 22:01:14.971228	{"rackid": 85, "shelf_id": 423, "shelf_number": 300}	{"rackid": 85, "shelf_id": 423, "shelf_number": 5000}
807	shelf	UPDATE	424	2025-03-29 22:01:14.971228	{"rackid": 85, "shelf_id": 424, "shelf_number": 400}	{"rackid": 85, "shelf_id": 424, "shelf_number": 5100}
808	shelf	UPDATE	425	2025-03-29 22:01:14.971228	{"rackid": 85, "shelf_id": 425, "shelf_number": 500}	{"rackid": 85, "shelf_id": 425, "shelf_number": 5200}
809	shelf	UPDATE	426	2025-03-29 22:01:14.971228	{"rackid": 86, "shelf_id": 426, "shelf_number": 100}	{"rackid": 86, "shelf_id": 426, "shelf_number": 4500}
810	shelf	UPDATE	427	2025-03-29 22:01:14.971228	{"rackid": 86, "shelf_id": 427, "shelf_number": 200}	{"rackid": 86, "shelf_id": 427, "shelf_number": 4600}
811	shelf	UPDATE	428	2025-03-29 22:01:14.971228	{"rackid": 86, "shelf_id": 428, "shelf_number": 300}	{"rackid": 86, "shelf_id": 428, "shelf_number": 4700}
812	shelf	UPDATE	429	2025-03-29 22:01:14.971228	{"rackid": 86, "shelf_id": 429, "shelf_number": 400}	{"rackid": 86, "shelf_id": 429, "shelf_number": 4800}
813	shelf	UPDATE	430	2025-03-29 22:01:14.971228	{"rackid": 86, "shelf_id": 430, "shelf_number": 500}	{"rackid": 86, "shelf_id": 430, "shelf_number": 4900}
814	shelf	UPDATE	431	2025-03-29 22:01:14.971228	{"rackid": 87, "shelf_id": 431, "shelf_number": 100}	{"rackid": 87, "shelf_id": 431, "shelf_number": 4600}
815	shelf	UPDATE	432	2025-03-29 22:01:14.971228	{"rackid": 87, "shelf_id": 432, "shelf_number": 200}	{"rackid": 87, "shelf_id": 432, "shelf_number": 4700}
816	shelf	UPDATE	433	2025-03-29 22:01:14.971228	{"rackid": 87, "shelf_id": 433, "shelf_number": 300}	{"rackid": 87, "shelf_id": 433, "shelf_number": 4800}
817	shelf	UPDATE	434	2025-03-29 22:01:14.971228	{"rackid": 87, "shelf_id": 434, "shelf_number": 400}	{"rackid": 87, "shelf_id": 434, "shelf_number": 4900}
818	shelf	UPDATE	435	2025-03-29 22:01:14.971228	{"rackid": 87, "shelf_id": 435, "shelf_number": 500}	{"rackid": 87, "shelf_id": 435, "shelf_number": 5000}
819	shelf	UPDATE	436	2025-03-29 22:01:14.971228	{"rackid": 88, "shelf_id": 436, "shelf_number": 100}	{"rackid": 88, "shelf_id": 436, "shelf_number": 4700}
820	shelf	UPDATE	437	2025-03-29 22:01:14.971228	{"rackid": 88, "shelf_id": 437, "shelf_number": 200}	{"rackid": 88, "shelf_id": 437, "shelf_number": 4800}
821	shelf	UPDATE	438	2025-03-29 22:01:14.971228	{"rackid": 88, "shelf_id": 438, "shelf_number": 300}	{"rackid": 88, "shelf_id": 438, "shelf_number": 4900}
822	shelf	UPDATE	439	2025-03-29 22:01:14.971228	{"rackid": 88, "shelf_id": 439, "shelf_number": 400}	{"rackid": 88, "shelf_id": 439, "shelf_number": 5000}
823	shelf	UPDATE	440	2025-03-29 22:01:14.971228	{"rackid": 88, "shelf_id": 440, "shelf_number": 500}	{"rackid": 88, "shelf_id": 440, "shelf_number": 5100}
824	shelf	UPDATE	441	2025-03-29 22:01:14.971228	{"rackid": 89, "shelf_id": 441, "shelf_number": 100}	{"rackid": 89, "shelf_id": 441, "shelf_number": 4800}
825	shelf	UPDATE	442	2025-03-29 22:01:14.971228	{"rackid": 89, "shelf_id": 442, "shelf_number": 200}	{"rackid": 89, "shelf_id": 442, "shelf_number": 4900}
826	shelf	UPDATE	443	2025-03-29 22:01:14.971228	{"rackid": 89, "shelf_id": 443, "shelf_number": 300}	{"rackid": 89, "shelf_id": 443, "shelf_number": 5000}
827	shelf	UPDATE	444	2025-03-29 22:01:14.971228	{"rackid": 89, "shelf_id": 444, "shelf_number": 400}	{"rackid": 89, "shelf_id": 444, "shelf_number": 5100}
828	shelf	UPDATE	445	2025-03-29 22:01:14.971228	{"rackid": 89, "shelf_id": 445, "shelf_number": 500}	{"rackid": 89, "shelf_id": 445, "shelf_number": 5200}
829	shelf	UPDATE	446	2025-03-29 22:01:14.971228	{"rackid": 90, "shelf_id": 446, "shelf_number": 100}	{"rackid": 90, "shelf_id": 446, "shelf_number": 4900}
830	shelf	UPDATE	447	2025-03-29 22:01:14.971228	{"rackid": 90, "shelf_id": 447, "shelf_number": 200}	{"rackid": 90, "shelf_id": 447, "shelf_number": 5000}
831	shelf	UPDATE	448	2025-03-29 22:01:14.971228	{"rackid": 90, "shelf_id": 448, "shelf_number": 300}	{"rackid": 90, "shelf_id": 448, "shelf_number": 5100}
832	shelf	UPDATE	449	2025-03-29 22:01:14.971228	{"rackid": 90, "shelf_id": 449, "shelf_number": 400}	{"rackid": 90, "shelf_id": 449, "shelf_number": 5200}
833	shelf	UPDATE	450	2025-03-29 22:01:14.971228	{"rackid": 90, "shelf_id": 450, "shelf_number": 500}	{"rackid": 90, "shelf_id": 450, "shelf_number": 5300}
834	shelf	UPDATE	451	2025-03-29 22:01:14.971228	{"rackid": 91, "shelf_id": 451, "shelf_number": 100}	{"rackid": 91, "shelf_id": 451, "shelf_number": 4600}
835	shelf	UPDATE	452	2025-03-29 22:01:14.971228	{"rackid": 91, "shelf_id": 452, "shelf_number": 200}	{"rackid": 91, "shelf_id": 452, "shelf_number": 4700}
836	shelf	UPDATE	453	2025-03-29 22:01:14.971228	{"rackid": 91, "shelf_id": 453, "shelf_number": 300}	{"rackid": 91, "shelf_id": 453, "shelf_number": 4800}
837	shelf	UPDATE	454	2025-03-29 22:01:14.971228	{"rackid": 91, "shelf_id": 454, "shelf_number": 400}	{"rackid": 91, "shelf_id": 454, "shelf_number": 4900}
838	shelf	UPDATE	455	2025-03-29 22:01:14.971228	{"rackid": 91, "shelf_id": 455, "shelf_number": 500}	{"rackid": 91, "shelf_id": 455, "shelf_number": 5000}
839	shelf	UPDATE	456	2025-03-29 22:01:14.971228	{"rackid": 92, "shelf_id": 456, "shelf_number": 100}	{"rackid": 92, "shelf_id": 456, "shelf_number": 4700}
840	shelf	UPDATE	457	2025-03-29 22:01:14.971228	{"rackid": 92, "shelf_id": 457, "shelf_number": 200}	{"rackid": 92, "shelf_id": 457, "shelf_number": 4800}
841	shelf	UPDATE	458	2025-03-29 22:01:14.971228	{"rackid": 92, "shelf_id": 458, "shelf_number": 300}	{"rackid": 92, "shelf_id": 458, "shelf_number": 4900}
842	shelf	UPDATE	459	2025-03-29 22:01:14.971228	{"rackid": 92, "shelf_id": 459, "shelf_number": 400}	{"rackid": 92, "shelf_id": 459, "shelf_number": 5000}
843	shelf	UPDATE	460	2025-03-29 22:01:14.971228	{"rackid": 92, "shelf_id": 460, "shelf_number": 500}	{"rackid": 92, "shelf_id": 460, "shelf_number": 5100}
844	shelf	UPDATE	461	2025-03-29 22:01:14.971228	{"rackid": 93, "shelf_id": 461, "shelf_number": 100}	{"rackid": 93, "shelf_id": 461, "shelf_number": 4800}
845	shelf	UPDATE	462	2025-03-29 22:01:14.971228	{"rackid": 93, "shelf_id": 462, "shelf_number": 200}	{"rackid": 93, "shelf_id": 462, "shelf_number": 4900}
846	shelf	UPDATE	463	2025-03-29 22:01:14.971228	{"rackid": 93, "shelf_id": 463, "shelf_number": 300}	{"rackid": 93, "shelf_id": 463, "shelf_number": 5000}
847	shelf	UPDATE	464	2025-03-29 22:01:14.971228	{"rackid": 93, "shelf_id": 464, "shelf_number": 400}	{"rackid": 93, "shelf_id": 464, "shelf_number": 5100}
848	shelf	UPDATE	465	2025-03-29 22:01:14.971228	{"rackid": 93, "shelf_id": 465, "shelf_number": 500}	{"rackid": 93, "shelf_id": 465, "shelf_number": 5200}
849	shelf	UPDATE	466	2025-03-29 22:01:14.971228	{"rackid": 94, "shelf_id": 466, "shelf_number": 100}	{"rackid": 94, "shelf_id": 466, "shelf_number": 4900}
850	shelf	UPDATE	467	2025-03-29 22:01:14.971228	{"rackid": 94, "shelf_id": 467, "shelf_number": 200}	{"rackid": 94, "shelf_id": 467, "shelf_number": 5000}
851	shelf	UPDATE	468	2025-03-29 22:01:14.971228	{"rackid": 94, "shelf_id": 468, "shelf_number": 300}	{"rackid": 94, "shelf_id": 468, "shelf_number": 5100}
852	shelf	UPDATE	469	2025-03-29 22:01:14.971228	{"rackid": 94, "shelf_id": 469, "shelf_number": 400}	{"rackid": 94, "shelf_id": 469, "shelf_number": 5200}
853	shelf	UPDATE	470	2025-03-29 22:01:14.971228	{"rackid": 94, "shelf_id": 470, "shelf_number": 500}	{"rackid": 94, "shelf_id": 470, "shelf_number": 5300}
854	shelf	UPDATE	471	2025-03-29 22:01:14.971228	{"rackid": 95, "shelf_id": 471, "shelf_number": 100}	{"rackid": 95, "shelf_id": 471, "shelf_number": 5000}
855	shelf	UPDATE	472	2025-03-29 22:01:14.971228	{"rackid": 95, "shelf_id": 472, "shelf_number": 200}	{"rackid": 95, "shelf_id": 472, "shelf_number": 5100}
856	shelf	UPDATE	473	2025-03-29 22:01:14.971228	{"rackid": 95, "shelf_id": 473, "shelf_number": 300}	{"rackid": 95, "shelf_id": 473, "shelf_number": 5200}
857	shelf	UPDATE	474	2025-03-29 22:01:14.971228	{"rackid": 95, "shelf_id": 474, "shelf_number": 400}	{"rackid": 95, "shelf_id": 474, "shelf_number": 5300}
858	shelf	UPDATE	475	2025-03-29 22:01:14.971228	{"rackid": 95, "shelf_id": 475, "shelf_number": 500}	{"rackid": 95, "shelf_id": 475, "shelf_number": 5400}
859	shelf	UPDATE	476	2025-03-29 22:01:14.971228	{"rackid": 96, "shelf_id": 476, "shelf_number": 100}	{"rackid": 96, "shelf_id": 476, "shelf_number": 4700}
860	shelf	UPDATE	477	2025-03-29 22:01:14.971228	{"rackid": 96, "shelf_id": 477, "shelf_number": 200}	{"rackid": 96, "shelf_id": 477, "shelf_number": 4800}
861	shelf	UPDATE	478	2025-03-29 22:01:14.971228	{"rackid": 96, "shelf_id": 478, "shelf_number": 300}	{"rackid": 96, "shelf_id": 478, "shelf_number": 4900}
862	shelf	UPDATE	479	2025-03-29 22:01:14.971228	{"rackid": 96, "shelf_id": 479, "shelf_number": 400}	{"rackid": 96, "shelf_id": 479, "shelf_number": 5000}
863	shelf	UPDATE	480	2025-03-29 22:01:14.971228	{"rackid": 96, "shelf_id": 480, "shelf_number": 500}	{"rackid": 96, "shelf_id": 480, "shelf_number": 5100}
864	shelf	UPDATE	481	2025-03-29 22:01:14.971228	{"rackid": 97, "shelf_id": 481, "shelf_number": 100}	{"rackid": 97, "shelf_id": 481, "shelf_number": 4800}
865	shelf	UPDATE	482	2025-03-29 22:01:14.971228	{"rackid": 97, "shelf_id": 482, "shelf_number": 200}	{"rackid": 97, "shelf_id": 482, "shelf_number": 4900}
866	shelf	UPDATE	483	2025-03-29 22:01:14.971228	{"rackid": 97, "shelf_id": 483, "shelf_number": 300}	{"rackid": 97, "shelf_id": 483, "shelf_number": 5000}
867	shelf	UPDATE	484	2025-03-29 22:01:14.971228	{"rackid": 97, "shelf_id": 484, "shelf_number": 400}	{"rackid": 97, "shelf_id": 484, "shelf_number": 5100}
868	shelf	UPDATE	485	2025-03-29 22:01:14.971228	{"rackid": 97, "shelf_id": 485, "shelf_number": 500}	{"rackid": 97, "shelf_id": 485, "shelf_number": 5200}
869	shelf	UPDATE	486	2025-03-29 22:01:14.971228	{"rackid": 98, "shelf_id": 486, "shelf_number": 100}	{"rackid": 98, "shelf_id": 486, "shelf_number": 4900}
870	shelf	UPDATE	487	2025-03-29 22:01:14.971228	{"rackid": 98, "shelf_id": 487, "shelf_number": 200}	{"rackid": 98, "shelf_id": 487, "shelf_number": 5000}
871	shelf	UPDATE	488	2025-03-29 22:01:14.971228	{"rackid": 98, "shelf_id": 488, "shelf_number": 300}	{"rackid": 98, "shelf_id": 488, "shelf_number": 5100}
872	shelf	UPDATE	489	2025-03-29 22:01:14.971228	{"rackid": 98, "shelf_id": 489, "shelf_number": 400}	{"rackid": 98, "shelf_id": 489, "shelf_number": 5200}
873	shelf	UPDATE	490	2025-03-29 22:01:14.971228	{"rackid": 98, "shelf_id": 490, "shelf_number": 500}	{"rackid": 98, "shelf_id": 490, "shelf_number": 5300}
874	shelf	UPDATE	491	2025-03-29 22:01:14.971228	{"rackid": 99, "shelf_id": 491, "shelf_number": 100}	{"rackid": 99, "shelf_id": 491, "shelf_number": 5000}
875	shelf	UPDATE	492	2025-03-29 22:01:14.971228	{"rackid": 99, "shelf_id": 492, "shelf_number": 200}	{"rackid": 99, "shelf_id": 492, "shelf_number": 5100}
876	shelf	UPDATE	493	2025-03-29 22:01:14.971228	{"rackid": 99, "shelf_id": 493, "shelf_number": 300}	{"rackid": 99, "shelf_id": 493, "shelf_number": 5200}
877	shelf	UPDATE	494	2025-03-29 22:01:14.971228	{"rackid": 99, "shelf_id": 494, "shelf_number": 400}	{"rackid": 99, "shelf_id": 494, "shelf_number": 5300}
878	shelf	UPDATE	495	2025-03-29 22:01:14.971228	{"rackid": 99, "shelf_id": 495, "shelf_number": 500}	{"rackid": 99, "shelf_id": 495, "shelf_number": 5400}
879	shelf	UPDATE	496	2025-03-29 22:01:14.971228	{"rackid": 100, "shelf_id": 496, "shelf_number": 100}	{"rackid": 100, "shelf_id": 496, "shelf_number": 5100}
880	shelf	UPDATE	497	2025-03-29 22:01:14.971228	{"rackid": 100, "shelf_id": 497, "shelf_number": 200}	{"rackid": 100, "shelf_id": 497, "shelf_number": 5200}
881	shelf	UPDATE	498	2025-03-29 22:01:14.971228	{"rackid": 100, "shelf_id": 498, "shelf_number": 300}	{"rackid": 100, "shelf_id": 498, "shelf_number": 5300}
882	shelf	UPDATE	499	2025-03-29 22:01:14.971228	{"rackid": 100, "shelf_id": 499, "shelf_number": 400}	{"rackid": 100, "shelf_id": 499, "shelf_number": 5400}
883	shelf	UPDATE	500	2025-03-29 22:01:14.971228	{"rackid": 100, "shelf_id": 500, "shelf_number": 500}	{"rackid": 100, "shelf_id": 500, "shelf_number": 5500}
884	shelf	UPDATE	501	2025-03-29 22:01:14.971228	{"rackid": 101, "shelf_id": 501, "shelf_number": 100}	{"rackid": 101, "shelf_id": 501, "shelf_number": 5300}
885	shelf	UPDATE	502	2025-03-29 22:01:14.971228	{"rackid": 101, "shelf_id": 502, "shelf_number": 200}	{"rackid": 101, "shelf_id": 502, "shelf_number": 5400}
886	shelf	UPDATE	503	2025-03-29 22:01:14.971228	{"rackid": 101, "shelf_id": 503, "shelf_number": 300}	{"rackid": 101, "shelf_id": 503, "shelf_number": 5500}
887	shelf	UPDATE	504	2025-03-29 22:01:14.971228	{"rackid": 101, "shelf_id": 504, "shelf_number": 400}	{"rackid": 101, "shelf_id": 504, "shelf_number": 5600}
888	shelf	UPDATE	505	2025-03-29 22:01:14.971228	{"rackid": 101, "shelf_id": 505, "shelf_number": 500}	{"rackid": 101, "shelf_id": 505, "shelf_number": 5700}
889	shelf	UPDATE	506	2025-03-29 22:01:14.971228	{"rackid": 102, "shelf_id": 506, "shelf_number": 100}	{"rackid": 102, "shelf_id": 506, "shelf_number": 5400}
890	shelf	UPDATE	507	2025-03-29 22:01:14.971228	{"rackid": 102, "shelf_id": 507, "shelf_number": 200}	{"rackid": 102, "shelf_id": 507, "shelf_number": 5500}
891	shelf	UPDATE	508	2025-03-29 22:01:14.971228	{"rackid": 102, "shelf_id": 508, "shelf_number": 300}	{"rackid": 102, "shelf_id": 508, "shelf_number": 5600}
892	shelf	UPDATE	509	2025-03-29 22:01:14.971228	{"rackid": 102, "shelf_id": 509, "shelf_number": 400}	{"rackid": 102, "shelf_id": 509, "shelf_number": 5700}
893	shelf	UPDATE	510	2025-03-29 22:01:14.971228	{"rackid": 102, "shelf_id": 510, "shelf_number": 500}	{"rackid": 102, "shelf_id": 510, "shelf_number": 5800}
894	shelf	UPDATE	511	2025-03-29 22:01:14.971228	{"rackid": 103, "shelf_id": 511, "shelf_number": 100}	{"rackid": 103, "shelf_id": 511, "shelf_number": 5500}
895	shelf	UPDATE	512	2025-03-29 22:01:14.971228	{"rackid": 103, "shelf_id": 512, "shelf_number": 200}	{"rackid": 103, "shelf_id": 512, "shelf_number": 5600}
896	shelf	UPDATE	513	2025-03-29 22:01:14.971228	{"rackid": 103, "shelf_id": 513, "shelf_number": 300}	{"rackid": 103, "shelf_id": 513, "shelf_number": 5700}
897	shelf	UPDATE	514	2025-03-29 22:01:14.971228	{"rackid": 103, "shelf_id": 514, "shelf_number": 400}	{"rackid": 103, "shelf_id": 514, "shelf_number": 5800}
898	shelf	UPDATE	515	2025-03-29 22:01:14.971228	{"rackid": 103, "shelf_id": 515, "shelf_number": 500}	{"rackid": 103, "shelf_id": 515, "shelf_number": 5900}
899	shelf	UPDATE	516	2025-03-29 22:01:14.971228	{"rackid": 104, "shelf_id": 516, "shelf_number": 100}	{"rackid": 104, "shelf_id": 516, "shelf_number": 5600}
900	shelf	UPDATE	517	2025-03-29 22:01:14.971228	{"rackid": 104, "shelf_id": 517, "shelf_number": 200}	{"rackid": 104, "shelf_id": 517, "shelf_number": 5700}
901	shelf	UPDATE	518	2025-03-29 22:01:14.971228	{"rackid": 104, "shelf_id": 518, "shelf_number": 300}	{"rackid": 104, "shelf_id": 518, "shelf_number": 5800}
902	shelf	UPDATE	519	2025-03-29 22:01:14.971228	{"rackid": 104, "shelf_id": 519, "shelf_number": 400}	{"rackid": 104, "shelf_id": 519, "shelf_number": 5900}
903	shelf	UPDATE	520	2025-03-29 22:01:14.971228	{"rackid": 104, "shelf_id": 520, "shelf_number": 500}	{"rackid": 104, "shelf_id": 520, "shelf_number": 6000}
904	shelf	UPDATE	521	2025-03-29 22:01:14.971228	{"rackid": 105, "shelf_id": 521, "shelf_number": 100}	{"rackid": 105, "shelf_id": 521, "shelf_number": 5700}
905	shelf	UPDATE	522	2025-03-29 22:01:14.971228	{"rackid": 105, "shelf_id": 522, "shelf_number": 200}	{"rackid": 105, "shelf_id": 522, "shelf_number": 5800}
906	shelf	UPDATE	523	2025-03-29 22:01:14.971228	{"rackid": 105, "shelf_id": 523, "shelf_number": 300}	{"rackid": 105, "shelf_id": 523, "shelf_number": 5900}
907	shelf	UPDATE	524	2025-03-29 22:01:14.971228	{"rackid": 105, "shelf_id": 524, "shelf_number": 400}	{"rackid": 105, "shelf_id": 524, "shelf_number": 6000}
908	shelf	UPDATE	525	2025-03-29 22:01:14.971228	{"rackid": 105, "shelf_id": 525, "shelf_number": 500}	{"rackid": 105, "shelf_id": 525, "shelf_number": 6100}
909	shelf	UPDATE	526	2025-03-29 22:01:14.971228	{"rackid": 106, "shelf_id": 526, "shelf_number": 100}	{"rackid": 106, "shelf_id": 526, "shelf_number": 5400}
910	shelf	UPDATE	527	2025-03-29 22:01:14.971228	{"rackid": 106, "shelf_id": 527, "shelf_number": 200}	{"rackid": 106, "shelf_id": 527, "shelf_number": 5500}
911	shelf	UPDATE	528	2025-03-29 22:01:14.971228	{"rackid": 106, "shelf_id": 528, "shelf_number": 300}	{"rackid": 106, "shelf_id": 528, "shelf_number": 5600}
912	shelf	UPDATE	529	2025-03-29 22:01:14.971228	{"rackid": 106, "shelf_id": 529, "shelf_number": 400}	{"rackid": 106, "shelf_id": 529, "shelf_number": 5700}
913	shelf	UPDATE	530	2025-03-29 22:01:14.971228	{"rackid": 106, "shelf_id": 530, "shelf_number": 500}	{"rackid": 106, "shelf_id": 530, "shelf_number": 5800}
914	shelf	UPDATE	531	2025-03-29 22:01:14.971228	{"rackid": 107, "shelf_id": 531, "shelf_number": 100}	{"rackid": 107, "shelf_id": 531, "shelf_number": 5500}
915	shelf	UPDATE	532	2025-03-29 22:01:14.971228	{"rackid": 107, "shelf_id": 532, "shelf_number": 200}	{"rackid": 107, "shelf_id": 532, "shelf_number": 5600}
916	shelf	UPDATE	533	2025-03-29 22:01:14.971228	{"rackid": 107, "shelf_id": 533, "shelf_number": 300}	{"rackid": 107, "shelf_id": 533, "shelf_number": 5700}
917	shelf	UPDATE	534	2025-03-29 22:01:14.971228	{"rackid": 107, "shelf_id": 534, "shelf_number": 400}	{"rackid": 107, "shelf_id": 534, "shelf_number": 5800}
918	shelf	UPDATE	535	2025-03-29 22:01:14.971228	{"rackid": 107, "shelf_id": 535, "shelf_number": 500}	{"rackid": 107, "shelf_id": 535, "shelf_number": 5900}
919	shelf	UPDATE	536	2025-03-29 22:01:14.971228	{"rackid": 108, "shelf_id": 536, "shelf_number": 100}	{"rackid": 108, "shelf_id": 536, "shelf_number": 5600}
920	shelf	UPDATE	537	2025-03-29 22:01:14.971228	{"rackid": 108, "shelf_id": 537, "shelf_number": 200}	{"rackid": 108, "shelf_id": 537, "shelf_number": 5700}
921	shelf	UPDATE	538	2025-03-29 22:01:14.971228	{"rackid": 108, "shelf_id": 538, "shelf_number": 300}	{"rackid": 108, "shelf_id": 538, "shelf_number": 5800}
922	shelf	UPDATE	539	2025-03-29 22:01:14.971228	{"rackid": 108, "shelf_id": 539, "shelf_number": 400}	{"rackid": 108, "shelf_id": 539, "shelf_number": 5900}
923	shelf	UPDATE	540	2025-03-29 22:01:14.971228	{"rackid": 108, "shelf_id": 540, "shelf_number": 500}	{"rackid": 108, "shelf_id": 540, "shelf_number": 6000}
924	shelf	UPDATE	541	2025-03-29 22:01:14.971228	{"rackid": 109, "shelf_id": 541, "shelf_number": 100}	{"rackid": 109, "shelf_id": 541, "shelf_number": 5700}
925	shelf	UPDATE	542	2025-03-29 22:01:14.971228	{"rackid": 109, "shelf_id": 542, "shelf_number": 200}	{"rackid": 109, "shelf_id": 542, "shelf_number": 5800}
926	shelf	UPDATE	543	2025-03-29 22:01:14.971228	{"rackid": 109, "shelf_id": 543, "shelf_number": 300}	{"rackid": 109, "shelf_id": 543, "shelf_number": 5900}
927	shelf	UPDATE	544	2025-03-29 22:01:14.971228	{"rackid": 109, "shelf_id": 544, "shelf_number": 400}	{"rackid": 109, "shelf_id": 544, "shelf_number": 6000}
928	shelf	UPDATE	545	2025-03-29 22:01:14.971228	{"rackid": 109, "shelf_id": 545, "shelf_number": 500}	{"rackid": 109, "shelf_id": 545, "shelf_number": 6100}
929	shelf	UPDATE	546	2025-03-29 22:01:14.971228	{"rackid": 110, "shelf_id": 546, "shelf_number": 100}	{"rackid": 110, "shelf_id": 546, "shelf_number": 5800}
930	shelf	UPDATE	547	2025-03-29 22:01:14.971228	{"rackid": 110, "shelf_id": 547, "shelf_number": 200}	{"rackid": 110, "shelf_id": 547, "shelf_number": 5900}
931	shelf	UPDATE	548	2025-03-29 22:01:14.971228	{"rackid": 110, "shelf_id": 548, "shelf_number": 300}	{"rackid": 110, "shelf_id": 548, "shelf_number": 6000}
932	shelf	UPDATE	549	2025-03-29 22:01:14.971228	{"rackid": 110, "shelf_id": 549, "shelf_number": 400}	{"rackid": 110, "shelf_id": 549, "shelf_number": 6100}
933	shelf	UPDATE	550	2025-03-29 22:01:14.971228	{"rackid": 110, "shelf_id": 550, "shelf_number": 500}	{"rackid": 110, "shelf_id": 550, "shelf_number": 6200}
934	shelf	UPDATE	551	2025-03-29 22:01:14.971228	{"rackid": 111, "shelf_id": 551, "shelf_number": 100}	{"rackid": 111, "shelf_id": 551, "shelf_number": 5500}
935	shelf	UPDATE	552	2025-03-29 22:01:14.971228	{"rackid": 111, "shelf_id": 552, "shelf_number": 200}	{"rackid": 111, "shelf_id": 552, "shelf_number": 5600}
936	shelf	UPDATE	553	2025-03-29 22:01:14.971228	{"rackid": 111, "shelf_id": 553, "shelf_number": 300}	{"rackid": 111, "shelf_id": 553, "shelf_number": 5700}
937	shelf	UPDATE	554	2025-03-29 22:01:14.971228	{"rackid": 111, "shelf_id": 554, "shelf_number": 400}	{"rackid": 111, "shelf_id": 554, "shelf_number": 5800}
938	shelf	UPDATE	555	2025-03-29 22:01:14.971228	{"rackid": 111, "shelf_id": 555, "shelf_number": 500}	{"rackid": 111, "shelf_id": 555, "shelf_number": 5900}
939	shelf	UPDATE	556	2025-03-29 22:01:14.971228	{"rackid": 112, "shelf_id": 556, "shelf_number": 100}	{"rackid": 112, "shelf_id": 556, "shelf_number": 5600}
940	shelf	UPDATE	557	2025-03-29 22:01:14.971228	{"rackid": 112, "shelf_id": 557, "shelf_number": 200}	{"rackid": 112, "shelf_id": 557, "shelf_number": 5700}
941	shelf	UPDATE	558	2025-03-29 22:01:14.971228	{"rackid": 112, "shelf_id": 558, "shelf_number": 300}	{"rackid": 112, "shelf_id": 558, "shelf_number": 5800}
942	shelf	UPDATE	559	2025-03-29 22:01:14.971228	{"rackid": 112, "shelf_id": 559, "shelf_number": 400}	{"rackid": 112, "shelf_id": 559, "shelf_number": 5900}
943	shelf	UPDATE	560	2025-03-29 22:01:14.971228	{"rackid": 112, "shelf_id": 560, "shelf_number": 500}	{"rackid": 112, "shelf_id": 560, "shelf_number": 6000}
944	shelf	UPDATE	561	2025-03-29 22:01:14.971228	{"rackid": 113, "shelf_id": 561, "shelf_number": 100}	{"rackid": 113, "shelf_id": 561, "shelf_number": 5700}
945	shelf	UPDATE	562	2025-03-29 22:01:14.971228	{"rackid": 113, "shelf_id": 562, "shelf_number": 200}	{"rackid": 113, "shelf_id": 562, "shelf_number": 5800}
946	shelf	UPDATE	563	2025-03-29 22:01:14.971228	{"rackid": 113, "shelf_id": 563, "shelf_number": 300}	{"rackid": 113, "shelf_id": 563, "shelf_number": 5900}
947	shelf	UPDATE	564	2025-03-29 22:01:14.971228	{"rackid": 113, "shelf_id": 564, "shelf_number": 400}	{"rackid": 113, "shelf_id": 564, "shelf_number": 6000}
948	shelf	UPDATE	565	2025-03-29 22:01:14.971228	{"rackid": 113, "shelf_id": 565, "shelf_number": 500}	{"rackid": 113, "shelf_id": 565, "shelf_number": 6100}
949	shelf	UPDATE	566	2025-03-29 22:01:14.971228	{"rackid": 114, "shelf_id": 566, "shelf_number": 100}	{"rackid": 114, "shelf_id": 566, "shelf_number": 5800}
950	shelf	UPDATE	567	2025-03-29 22:01:14.971228	{"rackid": 114, "shelf_id": 567, "shelf_number": 200}	{"rackid": 114, "shelf_id": 567, "shelf_number": 5900}
951	shelf	UPDATE	568	2025-03-29 22:01:14.971228	{"rackid": 114, "shelf_id": 568, "shelf_number": 300}	{"rackid": 114, "shelf_id": 568, "shelf_number": 6000}
952	shelf	UPDATE	569	2025-03-29 22:01:14.971228	{"rackid": 114, "shelf_id": 569, "shelf_number": 400}	{"rackid": 114, "shelf_id": 569, "shelf_number": 6100}
953	shelf	UPDATE	570	2025-03-29 22:01:14.971228	{"rackid": 114, "shelf_id": 570, "shelf_number": 500}	{"rackid": 114, "shelf_id": 570, "shelf_number": 6200}
954	shelf	UPDATE	571	2025-03-29 22:01:14.971228	{"rackid": 115, "shelf_id": 571, "shelf_number": 100}	{"rackid": 115, "shelf_id": 571, "shelf_number": 5900}
955	shelf	UPDATE	572	2025-03-29 22:01:14.971228	{"rackid": 115, "shelf_id": 572, "shelf_number": 200}	{"rackid": 115, "shelf_id": 572, "shelf_number": 6000}
956	shelf	UPDATE	573	2025-03-29 22:01:14.971228	{"rackid": 115, "shelf_id": 573, "shelf_number": 300}	{"rackid": 115, "shelf_id": 573, "shelf_number": 6100}
957	shelf	UPDATE	574	2025-03-29 22:01:14.971228	{"rackid": 115, "shelf_id": 574, "shelf_number": 400}	{"rackid": 115, "shelf_id": 574, "shelf_number": 6200}
958	shelf	UPDATE	575	2025-03-29 22:01:14.971228	{"rackid": 115, "shelf_id": 575, "shelf_number": 500}	{"rackid": 115, "shelf_id": 575, "shelf_number": 6300}
959	shelf	UPDATE	576	2025-03-29 22:01:14.971228	{"rackid": 116, "shelf_id": 576, "shelf_number": 100}	{"rackid": 116, "shelf_id": 576, "shelf_number": 5600}
960	shelf	UPDATE	577	2025-03-29 22:01:14.971228	{"rackid": 116, "shelf_id": 577, "shelf_number": 200}	{"rackid": 116, "shelf_id": 577, "shelf_number": 5700}
961	shelf	UPDATE	578	2025-03-29 22:01:14.971228	{"rackid": 116, "shelf_id": 578, "shelf_number": 300}	{"rackid": 116, "shelf_id": 578, "shelf_number": 5800}
962	shelf	UPDATE	579	2025-03-29 22:01:14.971228	{"rackid": 116, "shelf_id": 579, "shelf_number": 400}	{"rackid": 116, "shelf_id": 579, "shelf_number": 5900}
963	shelf	UPDATE	580	2025-03-29 22:01:14.971228	{"rackid": 116, "shelf_id": 580, "shelf_number": 500}	{"rackid": 116, "shelf_id": 580, "shelf_number": 6000}
964	shelf	UPDATE	581	2025-03-29 22:01:14.971228	{"rackid": 117, "shelf_id": 581, "shelf_number": 100}	{"rackid": 117, "shelf_id": 581, "shelf_number": 5700}
965	shelf	UPDATE	582	2025-03-29 22:01:14.971228	{"rackid": 117, "shelf_id": 582, "shelf_number": 200}	{"rackid": 117, "shelf_id": 582, "shelf_number": 5800}
966	shelf	UPDATE	583	2025-03-29 22:01:14.971228	{"rackid": 117, "shelf_id": 583, "shelf_number": 300}	{"rackid": 117, "shelf_id": 583, "shelf_number": 5900}
967	shelf	UPDATE	584	2025-03-29 22:01:14.971228	{"rackid": 117, "shelf_id": 584, "shelf_number": 400}	{"rackid": 117, "shelf_id": 584, "shelf_number": 6000}
968	shelf	UPDATE	585	2025-03-29 22:01:14.971228	{"rackid": 117, "shelf_id": 585, "shelf_number": 500}	{"rackid": 117, "shelf_id": 585, "shelf_number": 6100}
969	shelf	UPDATE	586	2025-03-29 22:01:14.971228	{"rackid": 118, "shelf_id": 586, "shelf_number": 100}	{"rackid": 118, "shelf_id": 586, "shelf_number": 5800}
970	shelf	UPDATE	587	2025-03-29 22:01:14.971228	{"rackid": 118, "shelf_id": 587, "shelf_number": 200}	{"rackid": 118, "shelf_id": 587, "shelf_number": 5900}
971	shelf	UPDATE	588	2025-03-29 22:01:14.971228	{"rackid": 118, "shelf_id": 588, "shelf_number": 300}	{"rackid": 118, "shelf_id": 588, "shelf_number": 6000}
972	shelf	UPDATE	589	2025-03-29 22:01:14.971228	{"rackid": 118, "shelf_id": 589, "shelf_number": 400}	{"rackid": 118, "shelf_id": 589, "shelf_number": 6100}
973	shelf	UPDATE	590	2025-03-29 22:01:14.971228	{"rackid": 118, "shelf_id": 590, "shelf_number": 500}	{"rackid": 118, "shelf_id": 590, "shelf_number": 6200}
974	shelf	UPDATE	591	2025-03-29 22:01:14.971228	{"rackid": 119, "shelf_id": 591, "shelf_number": 100}	{"rackid": 119, "shelf_id": 591, "shelf_number": 5900}
975	shelf	UPDATE	592	2025-03-29 22:01:14.971228	{"rackid": 119, "shelf_id": 592, "shelf_number": 200}	{"rackid": 119, "shelf_id": 592, "shelf_number": 6000}
976	shelf	UPDATE	593	2025-03-29 22:01:14.971228	{"rackid": 119, "shelf_id": 593, "shelf_number": 300}	{"rackid": 119, "shelf_id": 593, "shelf_number": 6100}
977	shelf	UPDATE	594	2025-03-29 22:01:14.971228	{"rackid": 119, "shelf_id": 594, "shelf_number": 400}	{"rackid": 119, "shelf_id": 594, "shelf_number": 6200}
978	shelf	UPDATE	595	2025-03-29 22:01:14.971228	{"rackid": 119, "shelf_id": 595, "shelf_number": 500}	{"rackid": 119, "shelf_id": 595, "shelf_number": 6300}
979	shelf	UPDATE	596	2025-03-29 22:01:14.971228	{"rackid": 120, "shelf_id": 596, "shelf_number": 100}	{"rackid": 120, "shelf_id": 596, "shelf_number": 6000}
980	shelf	UPDATE	597	2025-03-29 22:01:14.971228	{"rackid": 120, "shelf_id": 597, "shelf_number": 200}	{"rackid": 120, "shelf_id": 597, "shelf_number": 6100}
981	shelf	UPDATE	598	2025-03-29 22:01:14.971228	{"rackid": 120, "shelf_id": 598, "shelf_number": 300}	{"rackid": 120, "shelf_id": 598, "shelf_number": 6200}
982	shelf	UPDATE	599	2025-03-29 22:01:14.971228	{"rackid": 120, "shelf_id": 599, "shelf_number": 400}	{"rackid": 120, "shelf_id": 599, "shelf_number": 6300}
983	shelf	UPDATE	600	2025-03-29 22:01:14.971228	{"rackid": 120, "shelf_id": 600, "shelf_number": 500}	{"rackid": 120, "shelf_id": 600, "shelf_number": 6400}
984	shelf	UPDATE	601	2025-03-29 22:01:14.971228	{"rackid": 121, "shelf_id": 601, "shelf_number": 100}	{"rackid": 121, "shelf_id": 601, "shelf_number": 5700}
985	shelf	UPDATE	602	2025-03-29 22:01:14.971228	{"rackid": 121, "shelf_id": 602, "shelf_number": 200}	{"rackid": 121, "shelf_id": 602, "shelf_number": 5800}
986	shelf	UPDATE	603	2025-03-29 22:01:14.971228	{"rackid": 121, "shelf_id": 603, "shelf_number": 300}	{"rackid": 121, "shelf_id": 603, "shelf_number": 5900}
987	shelf	UPDATE	604	2025-03-29 22:01:14.971228	{"rackid": 121, "shelf_id": 604, "shelf_number": 400}	{"rackid": 121, "shelf_id": 604, "shelf_number": 6000}
988	shelf	UPDATE	605	2025-03-29 22:01:14.971228	{"rackid": 121, "shelf_id": 605, "shelf_number": 500}	{"rackid": 121, "shelf_id": 605, "shelf_number": 6100}
989	shelf	UPDATE	606	2025-03-29 22:01:14.971228	{"rackid": 122, "shelf_id": 606, "shelf_number": 100}	{"rackid": 122, "shelf_id": 606, "shelf_number": 5800}
990	shelf	UPDATE	607	2025-03-29 22:01:14.971228	{"rackid": 122, "shelf_id": 607, "shelf_number": 200}	{"rackid": 122, "shelf_id": 607, "shelf_number": 5900}
991	shelf	UPDATE	608	2025-03-29 22:01:14.971228	{"rackid": 122, "shelf_id": 608, "shelf_number": 300}	{"rackid": 122, "shelf_id": 608, "shelf_number": 6000}
992	shelf	UPDATE	609	2025-03-29 22:01:14.971228	{"rackid": 122, "shelf_id": 609, "shelf_number": 400}	{"rackid": 122, "shelf_id": 609, "shelf_number": 6100}
993	shelf	UPDATE	610	2025-03-29 22:01:14.971228	{"rackid": 122, "shelf_id": 610, "shelf_number": 500}	{"rackid": 122, "shelf_id": 610, "shelf_number": 6200}
994	shelf	UPDATE	611	2025-03-29 22:01:14.971228	{"rackid": 123, "shelf_id": 611, "shelf_number": 100}	{"rackid": 123, "shelf_id": 611, "shelf_number": 5900}
995	shelf	UPDATE	612	2025-03-29 22:01:14.971228	{"rackid": 123, "shelf_id": 612, "shelf_number": 200}	{"rackid": 123, "shelf_id": 612, "shelf_number": 6000}
996	shelf	UPDATE	613	2025-03-29 22:01:14.971228	{"rackid": 123, "shelf_id": 613, "shelf_number": 300}	{"rackid": 123, "shelf_id": 613, "shelf_number": 6100}
997	shelf	UPDATE	614	2025-03-29 22:01:14.971228	{"rackid": 123, "shelf_id": 614, "shelf_number": 400}	{"rackid": 123, "shelf_id": 614, "shelf_number": 6200}
998	shelf	UPDATE	615	2025-03-29 22:01:14.971228	{"rackid": 123, "shelf_id": 615, "shelf_number": 500}	{"rackid": 123, "shelf_id": 615, "shelf_number": 6300}
999	shelf	UPDATE	616	2025-03-29 22:01:14.971228	{"rackid": 124, "shelf_id": 616, "shelf_number": 100}	{"rackid": 124, "shelf_id": 616, "shelf_number": 6000}
1000	shelf	UPDATE	617	2025-03-29 22:01:14.971228	{"rackid": 124, "shelf_id": 617, "shelf_number": 200}	{"rackid": 124, "shelf_id": 617, "shelf_number": 6100}
1001	shelf	UPDATE	618	2025-03-29 22:01:14.971228	{"rackid": 124, "shelf_id": 618, "shelf_number": 300}	{"rackid": 124, "shelf_id": 618, "shelf_number": 6200}
1002	shelf	UPDATE	619	2025-03-29 22:01:14.971228	{"rackid": 124, "shelf_id": 619, "shelf_number": 400}	{"rackid": 124, "shelf_id": 619, "shelf_number": 6300}
1003	shelf	UPDATE	620	2025-03-29 22:01:14.971228	{"rackid": 124, "shelf_id": 620, "shelf_number": 500}	{"rackid": 124, "shelf_id": 620, "shelf_number": 6400}
1004	shelf	UPDATE	621	2025-03-29 22:01:14.971228	{"rackid": 125, "shelf_id": 621, "shelf_number": 100}	{"rackid": 125, "shelf_id": 621, "shelf_number": 6100}
1005	shelf	UPDATE	622	2025-03-29 22:01:14.971228	{"rackid": 125, "shelf_id": 622, "shelf_number": 200}	{"rackid": 125, "shelf_id": 622, "shelf_number": 6200}
1006	shelf	UPDATE	623	2025-03-29 22:01:14.971228	{"rackid": 125, "shelf_id": 623, "shelf_number": 300}	{"rackid": 125, "shelf_id": 623, "shelf_number": 6300}
1007	shelf	UPDATE	624	2025-03-29 22:01:14.971228	{"rackid": 125, "shelf_id": 624, "shelf_number": 400}	{"rackid": 125, "shelf_id": 624, "shelf_number": 6400}
1008	shelf	UPDATE	625	2025-03-29 22:01:14.971228	{"rackid": 125, "shelf_id": 625, "shelf_number": 500}	{"rackid": 125, "shelf_id": 625, "shelf_number": 6500}
1009	rack	UPDATE	1	2025-03-29 22:05:31.790941	{"roomid": 1, "rack_id": 1, "rack_number": 120}	{"roomid": 1, "rack_id": 1, "rack_number": 111}
1010	rack	UPDATE	2	2025-03-29 22:05:31.790941	{"roomid": 1, "rack_id": 2, "rack_number": 130}	{"roomid": 1, "rack_id": 2, "rack_number": 112}
1011	rack	UPDATE	3	2025-03-29 22:05:31.790941	{"roomid": 1, "rack_id": 3, "rack_number": 140}	{"roomid": 1, "rack_id": 3, "rack_number": 113}
1012	rack	UPDATE	4	2025-03-29 22:05:31.790941	{"roomid": 1, "rack_id": 4, "rack_number": 150}	{"roomid": 1, "rack_id": 4, "rack_number": 114}
1013	rack	UPDATE	5	2025-03-29 22:05:31.790941	{"roomid": 1, "rack_id": 5, "rack_number": 160}	{"roomid": 1, "rack_id": 5, "rack_number": 115}
1014	rack	UPDATE	6	2025-03-29 22:05:31.790941	{"roomid": 2, "rack_id": 6, "rack_number": 130}	{"roomid": 2, "rack_id": 6, "rack_number": 121}
1015	rack	UPDATE	7	2025-03-29 22:05:31.790941	{"roomid": 2, "rack_id": 7, "rack_number": 140}	{"roomid": 2, "rack_id": 7, "rack_number": 122}
1016	rack	UPDATE	8	2025-03-29 22:05:31.790941	{"roomid": 2, "rack_id": 8, "rack_number": 150}	{"roomid": 2, "rack_id": 8, "rack_number": 123}
1017	rack	UPDATE	9	2025-03-29 22:05:31.790941	{"roomid": 2, "rack_id": 9, "rack_number": 160}	{"roomid": 2, "rack_id": 9, "rack_number": 124}
1018	rack	UPDATE	10	2025-03-29 22:05:31.790941	{"roomid": 2, "rack_id": 10, "rack_number": 170}	{"roomid": 2, "rack_id": 10, "rack_number": 125}
1019	rack	UPDATE	11	2025-03-29 22:05:31.790941	{"roomid": 3, "rack_id": 11, "rack_number": 140}	{"roomid": 3, "rack_id": 11, "rack_number": 131}
1020	rack	UPDATE	12	2025-03-29 22:05:31.790941	{"roomid": 3, "rack_id": 12, "rack_number": 150}	{"roomid": 3, "rack_id": 12, "rack_number": 132}
1021	rack	UPDATE	13	2025-03-29 22:05:31.790941	{"roomid": 3, "rack_id": 13, "rack_number": 160}	{"roomid": 3, "rack_id": 13, "rack_number": 133}
1022	rack	UPDATE	14	2025-03-29 22:05:31.790941	{"roomid": 3, "rack_id": 14, "rack_number": 170}	{"roomid": 3, "rack_id": 14, "rack_number": 134}
1023	rack	UPDATE	15	2025-03-29 22:05:31.790941	{"roomid": 3, "rack_id": 15, "rack_number": 180}	{"roomid": 3, "rack_id": 15, "rack_number": 135}
1024	rack	UPDATE	16	2025-03-29 22:05:31.790941	{"roomid": 4, "rack_id": 16, "rack_number": 150}	{"roomid": 4, "rack_id": 16, "rack_number": 141}
1025	rack	UPDATE	17	2025-03-29 22:05:31.790941	{"roomid": 4, "rack_id": 17, "rack_number": 160}	{"roomid": 4, "rack_id": 17, "rack_number": 142}
1026	rack	UPDATE	18	2025-03-29 22:05:31.790941	{"roomid": 4, "rack_id": 18, "rack_number": 170}	{"roomid": 4, "rack_id": 18, "rack_number": 143}
1027	rack	UPDATE	19	2025-03-29 22:05:31.790941	{"roomid": 4, "rack_id": 19, "rack_number": 180}	{"roomid": 4, "rack_id": 19, "rack_number": 144}
1028	rack	UPDATE	20	2025-03-29 22:05:31.790941	{"roomid": 4, "rack_id": 20, "rack_number": 190}	{"roomid": 4, "rack_id": 20, "rack_number": 145}
1029	rack	UPDATE	21	2025-03-29 22:05:31.790941	{"roomid": 5, "rack_id": 21, "rack_number": 160}	{"roomid": 5, "rack_id": 21, "rack_number": 151}
1030	rack	UPDATE	22	2025-03-29 22:05:31.790941	{"roomid": 5, "rack_id": 22, "rack_number": 170}	{"roomid": 5, "rack_id": 22, "rack_number": 152}
1031	rack	UPDATE	23	2025-03-29 22:05:31.790941	{"roomid": 5, "rack_id": 23, "rack_number": 180}	{"roomid": 5, "rack_id": 23, "rack_number": 153}
1032	rack	UPDATE	24	2025-03-29 22:05:31.790941	{"roomid": 5, "rack_id": 24, "rack_number": 190}	{"roomid": 5, "rack_id": 24, "rack_number": 154}
1033	rack	UPDATE	25	2025-03-29 22:05:31.790941	{"roomid": 5, "rack_id": 25, "rack_number": 200}	{"roomid": 5, "rack_id": 25, "rack_number": 155}
1034	rack	UPDATE	26	2025-03-29 22:05:31.790941	{"roomid": 6, "rack_id": 26, "rack_number": 220}	{"roomid": 6, "rack_id": 26, "rack_number": 211}
1035	rack	UPDATE	27	2025-03-29 22:05:31.790941	{"roomid": 6, "rack_id": 27, "rack_number": 230}	{"roomid": 6, "rack_id": 27, "rack_number": 212}
1036	rack	UPDATE	28	2025-03-29 22:05:31.790941	{"roomid": 6, "rack_id": 28, "rack_number": 240}	{"roomid": 6, "rack_id": 28, "rack_number": 213}
1037	rack	UPDATE	29	2025-03-29 22:05:31.790941	{"roomid": 6, "rack_id": 29, "rack_number": 250}	{"roomid": 6, "rack_id": 29, "rack_number": 214}
1038	rack	UPDATE	30	2025-03-29 22:05:31.790941	{"roomid": 6, "rack_id": 30, "rack_number": 260}	{"roomid": 6, "rack_id": 30, "rack_number": 215}
1878	details	DELETE	14	2025-03-29 23:18:24.702358	{"weight": 7.3, "shelfid": 24, "detail_id": 14, "type_detail": "Фары"}	\N
1039	rack	UPDATE	31	2025-03-29 22:05:31.790941	{"roomid": 7, "rack_id": 31, "rack_number": 230}	{"roomid": 7, "rack_id": 31, "rack_number": 221}
1040	rack	UPDATE	32	2025-03-29 22:05:31.790941	{"roomid": 7, "rack_id": 32, "rack_number": 240}	{"roomid": 7, "rack_id": 32, "rack_number": 222}
1041	rack	UPDATE	33	2025-03-29 22:05:31.790941	{"roomid": 7, "rack_id": 33, "rack_number": 250}	{"roomid": 7, "rack_id": 33, "rack_number": 223}
1042	rack	UPDATE	34	2025-03-29 22:05:31.790941	{"roomid": 7, "rack_id": 34, "rack_number": 260}	{"roomid": 7, "rack_id": 34, "rack_number": 224}
1043	rack	UPDATE	35	2025-03-29 22:05:31.790941	{"roomid": 7, "rack_id": 35, "rack_number": 270}	{"roomid": 7, "rack_id": 35, "rack_number": 225}
1044	rack	UPDATE	36	2025-03-29 22:05:31.790941	{"roomid": 8, "rack_id": 36, "rack_number": 240}	{"roomid": 8, "rack_id": 36, "rack_number": 231}
1045	rack	UPDATE	37	2025-03-29 22:05:31.790941	{"roomid": 8, "rack_id": 37, "rack_number": 250}	{"roomid": 8, "rack_id": 37, "rack_number": 232}
1046	rack	UPDATE	38	2025-03-29 22:05:31.790941	{"roomid": 8, "rack_id": 38, "rack_number": 260}	{"roomid": 8, "rack_id": 38, "rack_number": 233}
1047	rack	UPDATE	39	2025-03-29 22:05:31.790941	{"roomid": 8, "rack_id": 39, "rack_number": 270}	{"roomid": 8, "rack_id": 39, "rack_number": 234}
1048	rack	UPDATE	40	2025-03-29 22:05:31.790941	{"roomid": 8, "rack_id": 40, "rack_number": 280}	{"roomid": 8, "rack_id": 40, "rack_number": 235}
1049	rack	UPDATE	41	2025-03-29 22:05:31.790941	{"roomid": 9, "rack_id": 41, "rack_number": 250}	{"roomid": 9, "rack_id": 41, "rack_number": 241}
1050	rack	UPDATE	42	2025-03-29 22:05:31.790941	{"roomid": 9, "rack_id": 42, "rack_number": 260}	{"roomid": 9, "rack_id": 42, "rack_number": 242}
1051	rack	UPDATE	43	2025-03-29 22:05:31.790941	{"roomid": 9, "rack_id": 43, "rack_number": 270}	{"roomid": 9, "rack_id": 43, "rack_number": 243}
1052	rack	UPDATE	44	2025-03-29 22:05:31.790941	{"roomid": 9, "rack_id": 44, "rack_number": 280}	{"roomid": 9, "rack_id": 44, "rack_number": 244}
1053	rack	UPDATE	45	2025-03-29 22:05:31.790941	{"roomid": 9, "rack_id": 45, "rack_number": 290}	{"roomid": 9, "rack_id": 45, "rack_number": 245}
1054	rack	UPDATE	46	2025-03-29 22:05:31.790941	{"roomid": 10, "rack_id": 46, "rack_number": 260}	{"roomid": 10, "rack_id": 46, "rack_number": 251}
1055	rack	UPDATE	47	2025-03-29 22:05:31.790941	{"roomid": 10, "rack_id": 47, "rack_number": 270}	{"roomid": 10, "rack_id": 47, "rack_number": 252}
1056	rack	UPDATE	48	2025-03-29 22:05:31.790941	{"roomid": 10, "rack_id": 48, "rack_number": 280}	{"roomid": 10, "rack_id": 48, "rack_number": 253}
1057	rack	UPDATE	49	2025-03-29 22:05:31.790941	{"roomid": 10, "rack_id": 49, "rack_number": 290}	{"roomid": 10, "rack_id": 49, "rack_number": 254}
1058	rack	UPDATE	50	2025-03-29 22:05:31.790941	{"roomid": 10, "rack_id": 50, "rack_number": 300}	{"roomid": 10, "rack_id": 50, "rack_number": 255}
1059	rack	UPDATE	51	2025-03-29 22:05:31.790941	{"roomid": 11, "rack_id": 51, "rack_number": 320}	{"roomid": 11, "rack_id": 51, "rack_number": 311}
1060	rack	UPDATE	52	2025-03-29 22:05:31.790941	{"roomid": 11, "rack_id": 52, "rack_number": 330}	{"roomid": 11, "rack_id": 52, "rack_number": 312}
1061	rack	UPDATE	53	2025-03-29 22:05:31.790941	{"roomid": 11, "rack_id": 53, "rack_number": 340}	{"roomid": 11, "rack_id": 53, "rack_number": 313}
1062	rack	UPDATE	54	2025-03-29 22:05:31.790941	{"roomid": 11, "rack_id": 54, "rack_number": 350}	{"roomid": 11, "rack_id": 54, "rack_number": 314}
1063	rack	UPDATE	55	2025-03-29 22:05:31.790941	{"roomid": 11, "rack_id": 55, "rack_number": 360}	{"roomid": 11, "rack_id": 55, "rack_number": 315}
1064	rack	UPDATE	56	2025-03-29 22:05:31.790941	{"roomid": 12, "rack_id": 56, "rack_number": 330}	{"roomid": 12, "rack_id": 56, "rack_number": 321}
1065	rack	UPDATE	57	2025-03-29 22:05:31.790941	{"roomid": 12, "rack_id": 57, "rack_number": 340}	{"roomid": 12, "rack_id": 57, "rack_number": 322}
1066	rack	UPDATE	58	2025-03-29 22:05:31.790941	{"roomid": 12, "rack_id": 58, "rack_number": 350}	{"roomid": 12, "rack_id": 58, "rack_number": 323}
1067	rack	UPDATE	59	2025-03-29 22:05:31.790941	{"roomid": 12, "rack_id": 59, "rack_number": 360}	{"roomid": 12, "rack_id": 59, "rack_number": 324}
1068	rack	UPDATE	60	2025-03-29 22:05:31.790941	{"roomid": 12, "rack_id": 60, "rack_number": 370}	{"roomid": 12, "rack_id": 60, "rack_number": 325}
1069	rack	UPDATE	61	2025-03-29 22:05:31.790941	{"roomid": 13, "rack_id": 61, "rack_number": 340}	{"roomid": 13, "rack_id": 61, "rack_number": 331}
1070	rack	UPDATE	62	2025-03-29 22:05:31.790941	{"roomid": 13, "rack_id": 62, "rack_number": 350}	{"roomid": 13, "rack_id": 62, "rack_number": 332}
1071	rack	UPDATE	63	2025-03-29 22:05:31.790941	{"roomid": 13, "rack_id": 63, "rack_number": 360}	{"roomid": 13, "rack_id": 63, "rack_number": 333}
1072	rack	UPDATE	64	2025-03-29 22:05:31.790941	{"roomid": 13, "rack_id": 64, "rack_number": 370}	{"roomid": 13, "rack_id": 64, "rack_number": 334}
1073	rack	UPDATE	65	2025-03-29 22:05:31.790941	{"roomid": 13, "rack_id": 65, "rack_number": 380}	{"roomid": 13, "rack_id": 65, "rack_number": 335}
1074	rack	UPDATE	66	2025-03-29 22:05:31.790941	{"roomid": 14, "rack_id": 66, "rack_number": 350}	{"roomid": 14, "rack_id": 66, "rack_number": 341}
1075	rack	UPDATE	67	2025-03-29 22:05:31.790941	{"roomid": 14, "rack_id": 67, "rack_number": 360}	{"roomid": 14, "rack_id": 67, "rack_number": 342}
1076	rack	UPDATE	68	2025-03-29 22:05:31.790941	{"roomid": 14, "rack_id": 68, "rack_number": 370}	{"roomid": 14, "rack_id": 68, "rack_number": 343}
1077	rack	UPDATE	69	2025-03-29 22:05:31.790941	{"roomid": 14, "rack_id": 69, "rack_number": 380}	{"roomid": 14, "rack_id": 69, "rack_number": 344}
1078	rack	UPDATE	70	2025-03-29 22:05:31.790941	{"roomid": 14, "rack_id": 70, "rack_number": 390}	{"roomid": 14, "rack_id": 70, "rack_number": 345}
1079	rack	UPDATE	71	2025-03-29 22:05:31.790941	{"roomid": 15, "rack_id": 71, "rack_number": 360}	{"roomid": 15, "rack_id": 71, "rack_number": 351}
1080	rack	UPDATE	72	2025-03-29 22:05:31.790941	{"roomid": 15, "rack_id": 72, "rack_number": 370}	{"roomid": 15, "rack_id": 72, "rack_number": 352}
1081	rack	UPDATE	73	2025-03-29 22:05:31.790941	{"roomid": 15, "rack_id": 73, "rack_number": 380}	{"roomid": 15, "rack_id": 73, "rack_number": 353}
1082	rack	UPDATE	74	2025-03-29 22:05:31.790941	{"roomid": 15, "rack_id": 74, "rack_number": 390}	{"roomid": 15, "rack_id": 74, "rack_number": 354}
1083	rack	UPDATE	75	2025-03-29 22:05:31.790941	{"roomid": 15, "rack_id": 75, "rack_number": 400}	{"roomid": 15, "rack_id": 75, "rack_number": 355}
1084	rack	UPDATE	76	2025-03-29 22:05:31.790941	{"roomid": 16, "rack_id": 76, "rack_number": 420}	{"roomid": 16, "rack_id": 76, "rack_number": 411}
1085	rack	UPDATE	77	2025-03-29 22:05:31.790941	{"roomid": 16, "rack_id": 77, "rack_number": 430}	{"roomid": 16, "rack_id": 77, "rack_number": 412}
1086	rack	UPDATE	78	2025-03-29 22:05:31.790941	{"roomid": 16, "rack_id": 78, "rack_number": 440}	{"roomid": 16, "rack_id": 78, "rack_number": 413}
1087	rack	UPDATE	79	2025-03-29 22:05:31.790941	{"roomid": 16, "rack_id": 79, "rack_number": 450}	{"roomid": 16, "rack_id": 79, "rack_number": 414}
1088	rack	UPDATE	80	2025-03-29 22:05:31.790941	{"roomid": 16, "rack_id": 80, "rack_number": 460}	{"roomid": 16, "rack_id": 80, "rack_number": 415}
1089	rack	UPDATE	81	2025-03-29 22:05:31.790941	{"roomid": 17, "rack_id": 81, "rack_number": 430}	{"roomid": 17, "rack_id": 81, "rack_number": 421}
1090	rack	UPDATE	82	2025-03-29 22:05:31.790941	{"roomid": 17, "rack_id": 82, "rack_number": 440}	{"roomid": 17, "rack_id": 82, "rack_number": 422}
1091	rack	UPDATE	83	2025-03-29 22:05:31.790941	{"roomid": 17, "rack_id": 83, "rack_number": 450}	{"roomid": 17, "rack_id": 83, "rack_number": 423}
1092	rack	UPDATE	84	2025-03-29 22:05:31.790941	{"roomid": 17, "rack_id": 84, "rack_number": 460}	{"roomid": 17, "rack_id": 84, "rack_number": 424}
1093	rack	UPDATE	85	2025-03-29 22:05:31.790941	{"roomid": 17, "rack_id": 85, "rack_number": 470}	{"roomid": 17, "rack_id": 85, "rack_number": 425}
1094	rack	UPDATE	86	2025-03-29 22:05:31.790941	{"roomid": 18, "rack_id": 86, "rack_number": 440}	{"roomid": 18, "rack_id": 86, "rack_number": 431}
1095	rack	UPDATE	87	2025-03-29 22:05:31.790941	{"roomid": 18, "rack_id": 87, "rack_number": 450}	{"roomid": 18, "rack_id": 87, "rack_number": 432}
1096	rack	UPDATE	88	2025-03-29 22:05:31.790941	{"roomid": 18, "rack_id": 88, "rack_number": 460}	{"roomid": 18, "rack_id": 88, "rack_number": 433}
1097	rack	UPDATE	89	2025-03-29 22:05:31.790941	{"roomid": 18, "rack_id": 89, "rack_number": 470}	{"roomid": 18, "rack_id": 89, "rack_number": 434}
1098	rack	UPDATE	90	2025-03-29 22:05:31.790941	{"roomid": 18, "rack_id": 90, "rack_number": 480}	{"roomid": 18, "rack_id": 90, "rack_number": 435}
1099	rack	UPDATE	91	2025-03-29 22:05:31.790941	{"roomid": 19, "rack_id": 91, "rack_number": 450}	{"roomid": 19, "rack_id": 91, "rack_number": 441}
1100	rack	UPDATE	92	2025-03-29 22:05:31.790941	{"roomid": 19, "rack_id": 92, "rack_number": 460}	{"roomid": 19, "rack_id": 92, "rack_number": 442}
1101	rack	UPDATE	93	2025-03-29 22:05:31.790941	{"roomid": 19, "rack_id": 93, "rack_number": 470}	{"roomid": 19, "rack_id": 93, "rack_number": 443}
1102	rack	UPDATE	94	2025-03-29 22:05:31.790941	{"roomid": 19, "rack_id": 94, "rack_number": 480}	{"roomid": 19, "rack_id": 94, "rack_number": 444}
1103	rack	UPDATE	95	2025-03-29 22:05:31.790941	{"roomid": 19, "rack_id": 95, "rack_number": 490}	{"roomid": 19, "rack_id": 95, "rack_number": 445}
1104	rack	UPDATE	96	2025-03-29 22:05:31.790941	{"roomid": 20, "rack_id": 96, "rack_number": 460}	{"roomid": 20, "rack_id": 96, "rack_number": 451}
1105	rack	UPDATE	97	2025-03-29 22:05:31.790941	{"roomid": 20, "rack_id": 97, "rack_number": 470}	{"roomid": 20, "rack_id": 97, "rack_number": 452}
1106	rack	UPDATE	98	2025-03-29 22:05:31.790941	{"roomid": 20, "rack_id": 98, "rack_number": 480}	{"roomid": 20, "rack_id": 98, "rack_number": 453}
1107	rack	UPDATE	99	2025-03-29 22:05:31.790941	{"roomid": 20, "rack_id": 99, "rack_number": 490}	{"roomid": 20, "rack_id": 99, "rack_number": 454}
1108	rack	UPDATE	100	2025-03-29 22:05:31.790941	{"roomid": 20, "rack_id": 100, "rack_number": 500}	{"roomid": 20, "rack_id": 100, "rack_number": 455}
1109	rack	UPDATE	101	2025-03-29 22:05:31.790941	{"roomid": 21, "rack_id": 101, "rack_number": 520}	{"roomid": 21, "rack_id": 101, "rack_number": 511}
1110	rack	UPDATE	102	2025-03-29 22:05:31.790941	{"roomid": 21, "rack_id": 102, "rack_number": 530}	{"roomid": 21, "rack_id": 102, "rack_number": 512}
1111	rack	UPDATE	103	2025-03-29 22:05:31.790941	{"roomid": 21, "rack_id": 103, "rack_number": 540}	{"roomid": 21, "rack_id": 103, "rack_number": 513}
1112	rack	UPDATE	104	2025-03-29 22:05:31.790941	{"roomid": 21, "rack_id": 104, "rack_number": 550}	{"roomid": 21, "rack_id": 104, "rack_number": 514}
1113	rack	UPDATE	105	2025-03-29 22:05:31.790941	{"roomid": 21, "rack_id": 105, "rack_number": 560}	{"roomid": 21, "rack_id": 105, "rack_number": 515}
1114	rack	UPDATE	106	2025-03-29 22:05:31.790941	{"roomid": 22, "rack_id": 106, "rack_number": 530}	{"roomid": 22, "rack_id": 106, "rack_number": 521}
1115	rack	UPDATE	107	2025-03-29 22:05:31.790941	{"roomid": 22, "rack_id": 107, "rack_number": 540}	{"roomid": 22, "rack_id": 107, "rack_number": 522}
1116	rack	UPDATE	108	2025-03-29 22:05:31.790941	{"roomid": 22, "rack_id": 108, "rack_number": 550}	{"roomid": 22, "rack_id": 108, "rack_number": 523}
1117	rack	UPDATE	109	2025-03-29 22:05:31.790941	{"roomid": 22, "rack_id": 109, "rack_number": 560}	{"roomid": 22, "rack_id": 109, "rack_number": 524}
1118	rack	UPDATE	110	2025-03-29 22:05:31.790941	{"roomid": 22, "rack_id": 110, "rack_number": 570}	{"roomid": 22, "rack_id": 110, "rack_number": 525}
1119	rack	UPDATE	111	2025-03-29 22:05:31.790941	{"roomid": 23, "rack_id": 111, "rack_number": 540}	{"roomid": 23, "rack_id": 111, "rack_number": 531}
1120	rack	UPDATE	112	2025-03-29 22:05:31.790941	{"roomid": 23, "rack_id": 112, "rack_number": 550}	{"roomid": 23, "rack_id": 112, "rack_number": 532}
1121	rack	UPDATE	113	2025-03-29 22:05:31.790941	{"roomid": 23, "rack_id": 113, "rack_number": 560}	{"roomid": 23, "rack_id": 113, "rack_number": 533}
1122	rack	UPDATE	114	2025-03-29 22:05:31.790941	{"roomid": 23, "rack_id": 114, "rack_number": 570}	{"roomid": 23, "rack_id": 114, "rack_number": 534}
1123	rack	UPDATE	115	2025-03-29 22:05:31.790941	{"roomid": 23, "rack_id": 115, "rack_number": 580}	{"roomid": 23, "rack_id": 115, "rack_number": 535}
1124	rack	UPDATE	116	2025-03-29 22:05:31.790941	{"roomid": 24, "rack_id": 116, "rack_number": 550}	{"roomid": 24, "rack_id": 116, "rack_number": 541}
1125	rack	UPDATE	117	2025-03-29 22:05:31.790941	{"roomid": 24, "rack_id": 117, "rack_number": 560}	{"roomid": 24, "rack_id": 117, "rack_number": 542}
1126	rack	UPDATE	118	2025-03-29 22:05:31.790941	{"roomid": 24, "rack_id": 118, "rack_number": 570}	{"roomid": 24, "rack_id": 118, "rack_number": 543}
1127	rack	UPDATE	119	2025-03-29 22:05:31.790941	{"roomid": 24, "rack_id": 119, "rack_number": 580}	{"roomid": 24, "rack_id": 119, "rack_number": 544}
1128	rack	UPDATE	120	2025-03-29 22:05:31.790941	{"roomid": 24, "rack_id": 120, "rack_number": 590}	{"roomid": 24, "rack_id": 120, "rack_number": 545}
1129	rack	UPDATE	121	2025-03-29 22:05:31.790941	{"roomid": 25, "rack_id": 121, "rack_number": 560}	{"roomid": 25, "rack_id": 121, "rack_number": 551}
1130	rack	UPDATE	122	2025-03-29 22:05:31.790941	{"roomid": 25, "rack_id": 122, "rack_number": 570}	{"roomid": 25, "rack_id": 122, "rack_number": 552}
1131	rack	UPDATE	123	2025-03-29 22:05:31.790941	{"roomid": 25, "rack_id": 123, "rack_number": 580}	{"roomid": 25, "rack_id": 123, "rack_number": 553}
1132	rack	UPDATE	124	2025-03-29 22:05:31.790941	{"roomid": 25, "rack_id": 124, "rack_number": 590}	{"roomid": 25, "rack_id": 124, "rack_number": 554}
1133	rack	UPDATE	125	2025-03-29 22:05:31.790941	{"roomid": 25, "rack_id": 125, "rack_number": 600}	{"roomid": 25, "rack_id": 125, "rack_number": 555}
1134	rack	UPDATE	126	2025-03-29 22:05:31.790941	{"roomid": 26, "rack_id": 126, "rack_number": 620}	{"roomid": 26, "rack_id": 126, "rack_number": 611}
1135	shelf	UPDATE	1	2025-03-29 22:06:31.687391	{"rackid": 1, "shelf_id": 1, "shelf_number": 1300}	{"rackid": 1, "shelf_id": 1, "shelf_number": 1111}
1136	shelf	UPDATE	2	2025-03-29 22:06:31.687391	{"rackid": 1, "shelf_id": 2, "shelf_number": 1400}	{"rackid": 1, "shelf_id": 2, "shelf_number": 1112}
1137	shelf	UPDATE	3	2025-03-29 22:06:31.687391	{"rackid": 1, "shelf_id": 3, "shelf_number": 1500}	{"rackid": 1, "shelf_id": 3, "shelf_number": 1113}
1138	shelf	UPDATE	4	2025-03-29 22:06:31.687391	{"rackid": 1, "shelf_id": 4, "shelf_number": 1600}	{"rackid": 1, "shelf_id": 4, "shelf_number": 1114}
1139	shelf	UPDATE	5	2025-03-29 22:06:31.687391	{"rackid": 1, "shelf_id": 5, "shelf_number": 1700}	{"rackid": 1, "shelf_id": 5, "shelf_number": 1115}
1140	shelf	UPDATE	6	2025-03-29 22:06:31.687391	{"rackid": 2, "shelf_id": 6, "shelf_number": 1400}	{"rackid": 2, "shelf_id": 6, "shelf_number": 1121}
1141	shelf	UPDATE	7	2025-03-29 22:06:31.687391	{"rackid": 2, "shelf_id": 7, "shelf_number": 1500}	{"rackid": 2, "shelf_id": 7, "shelf_number": 1122}
1142	shelf	UPDATE	8	2025-03-29 22:06:31.687391	{"rackid": 2, "shelf_id": 8, "shelf_number": 1600}	{"rackid": 2, "shelf_id": 8, "shelf_number": 1123}
1143	shelf	UPDATE	9	2025-03-29 22:06:31.687391	{"rackid": 2, "shelf_id": 9, "shelf_number": 1700}	{"rackid": 2, "shelf_id": 9, "shelf_number": 1124}
1144	shelf	UPDATE	10	2025-03-29 22:06:31.687391	{"rackid": 2, "shelf_id": 10, "shelf_number": 1800}	{"rackid": 2, "shelf_id": 10, "shelf_number": 1125}
1145	shelf	UPDATE	11	2025-03-29 22:06:31.687391	{"rackid": 3, "shelf_id": 11, "shelf_number": 1500}	{"rackid": 3, "shelf_id": 11, "shelf_number": 1131}
1146	shelf	UPDATE	12	2025-03-29 22:06:31.687391	{"rackid": 3, "shelf_id": 12, "shelf_number": 1600}	{"rackid": 3, "shelf_id": 12, "shelf_number": 1132}
1147	shelf	UPDATE	13	2025-03-29 22:06:31.687391	{"rackid": 3, "shelf_id": 13, "shelf_number": 1700}	{"rackid": 3, "shelf_id": 13, "shelf_number": 1133}
1148	shelf	UPDATE	14	2025-03-29 22:06:31.687391	{"rackid": 3, "shelf_id": 14, "shelf_number": 1800}	{"rackid": 3, "shelf_id": 14, "shelf_number": 1134}
1149	shelf	UPDATE	15	2025-03-29 22:06:31.687391	{"rackid": 3, "shelf_id": 15, "shelf_number": 1900}	{"rackid": 3, "shelf_id": 15, "shelf_number": 1135}
1150	shelf	UPDATE	16	2025-03-29 22:06:31.687391	{"rackid": 4, "shelf_id": 16, "shelf_number": 1600}	{"rackid": 4, "shelf_id": 16, "shelf_number": 1141}
1151	shelf	UPDATE	17	2025-03-29 22:06:31.687391	{"rackid": 4, "shelf_id": 17, "shelf_number": 1700}	{"rackid": 4, "shelf_id": 17, "shelf_number": 1142}
1152	shelf	UPDATE	18	2025-03-29 22:06:31.687391	{"rackid": 4, "shelf_id": 18, "shelf_number": 1800}	{"rackid": 4, "shelf_id": 18, "shelf_number": 1143}
1153	shelf	UPDATE	19	2025-03-29 22:06:31.687391	{"rackid": 4, "shelf_id": 19, "shelf_number": 1900}	{"rackid": 4, "shelf_id": 19, "shelf_number": 1144}
1154	shelf	UPDATE	20	2025-03-29 22:06:31.687391	{"rackid": 4, "shelf_id": 20, "shelf_number": 2000}	{"rackid": 4, "shelf_id": 20, "shelf_number": 1145}
1155	shelf	UPDATE	21	2025-03-29 22:06:31.687391	{"rackid": 5, "shelf_id": 21, "shelf_number": 1700}	{"rackid": 5, "shelf_id": 21, "shelf_number": 1151}
1156	shelf	UPDATE	22	2025-03-29 22:06:31.687391	{"rackid": 5, "shelf_id": 22, "shelf_number": 1800}	{"rackid": 5, "shelf_id": 22, "shelf_number": 1152}
1157	shelf	UPDATE	23	2025-03-29 22:06:31.687391	{"rackid": 5, "shelf_id": 23, "shelf_number": 1900}	{"rackid": 5, "shelf_id": 23, "shelf_number": 1153}
1158	shelf	UPDATE	24	2025-03-29 22:06:31.687391	{"rackid": 5, "shelf_id": 24, "shelf_number": 2000}	{"rackid": 5, "shelf_id": 24, "shelf_number": 1154}
1159	shelf	UPDATE	25	2025-03-29 22:06:31.687391	{"rackid": 5, "shelf_id": 25, "shelf_number": 2100}	{"rackid": 5, "shelf_id": 25, "shelf_number": 1155}
1160	shelf	UPDATE	26	2025-03-29 22:06:31.687391	{"rackid": 6, "shelf_id": 26, "shelf_number": 1400}	{"rackid": 6, "shelf_id": 26, "shelf_number": 1211}
1161	shelf	UPDATE	27	2025-03-29 22:06:31.687391	{"rackid": 6, "shelf_id": 27, "shelf_number": 1500}	{"rackid": 6, "shelf_id": 27, "shelf_number": 1212}
1162	shelf	UPDATE	28	2025-03-29 22:06:31.687391	{"rackid": 6, "shelf_id": 28, "shelf_number": 1600}	{"rackid": 6, "shelf_id": 28, "shelf_number": 1213}
1163	shelf	UPDATE	29	2025-03-29 22:06:31.687391	{"rackid": 6, "shelf_id": 29, "shelf_number": 1700}	{"rackid": 6, "shelf_id": 29, "shelf_number": 1214}
1164	shelf	UPDATE	30	2025-03-29 22:06:31.687391	{"rackid": 6, "shelf_id": 30, "shelf_number": 1800}	{"rackid": 6, "shelf_id": 30, "shelf_number": 1215}
1165	shelf	UPDATE	31	2025-03-29 22:06:31.687391	{"rackid": 7, "shelf_id": 31, "shelf_number": 1500}	{"rackid": 7, "shelf_id": 31, "shelf_number": 1221}
1166	shelf	UPDATE	32	2025-03-29 22:06:31.687391	{"rackid": 7, "shelf_id": 32, "shelf_number": 1600}	{"rackid": 7, "shelf_id": 32, "shelf_number": 1222}
1167	shelf	UPDATE	33	2025-03-29 22:06:31.687391	{"rackid": 7, "shelf_id": 33, "shelf_number": 1700}	{"rackid": 7, "shelf_id": 33, "shelf_number": 1223}
1168	shelf	UPDATE	34	2025-03-29 22:06:31.687391	{"rackid": 7, "shelf_id": 34, "shelf_number": 1800}	{"rackid": 7, "shelf_id": 34, "shelf_number": 1224}
1169	shelf	UPDATE	35	2025-03-29 22:06:31.687391	{"rackid": 7, "shelf_id": 35, "shelf_number": 1900}	{"rackid": 7, "shelf_id": 35, "shelf_number": 1225}
1170	shelf	UPDATE	36	2025-03-29 22:06:31.687391	{"rackid": 8, "shelf_id": 36, "shelf_number": 1600}	{"rackid": 8, "shelf_id": 36, "shelf_number": 1231}
1171	shelf	UPDATE	37	2025-03-29 22:06:31.687391	{"rackid": 8, "shelf_id": 37, "shelf_number": 1700}	{"rackid": 8, "shelf_id": 37, "shelf_number": 1232}
1172	shelf	UPDATE	38	2025-03-29 22:06:31.687391	{"rackid": 8, "shelf_id": 38, "shelf_number": 1800}	{"rackid": 8, "shelf_id": 38, "shelf_number": 1233}
1173	shelf	UPDATE	39	2025-03-29 22:06:31.687391	{"rackid": 8, "shelf_id": 39, "shelf_number": 1900}	{"rackid": 8, "shelf_id": 39, "shelf_number": 1234}
1174	shelf	UPDATE	40	2025-03-29 22:06:31.687391	{"rackid": 8, "shelf_id": 40, "shelf_number": 2000}	{"rackid": 8, "shelf_id": 40, "shelf_number": 1235}
1175	shelf	UPDATE	41	2025-03-29 22:06:31.687391	{"rackid": 9, "shelf_id": 41, "shelf_number": 1700}	{"rackid": 9, "shelf_id": 41, "shelf_number": 1241}
1176	shelf	UPDATE	42	2025-03-29 22:06:31.687391	{"rackid": 9, "shelf_id": 42, "shelf_number": 1800}	{"rackid": 9, "shelf_id": 42, "shelf_number": 1242}
1177	shelf	UPDATE	43	2025-03-29 22:06:31.687391	{"rackid": 9, "shelf_id": 43, "shelf_number": 1900}	{"rackid": 9, "shelf_id": 43, "shelf_number": 1243}
1178	shelf	UPDATE	44	2025-03-29 22:06:31.687391	{"rackid": 9, "shelf_id": 44, "shelf_number": 2000}	{"rackid": 9, "shelf_id": 44, "shelf_number": 1244}
1179	shelf	UPDATE	45	2025-03-29 22:06:31.687391	{"rackid": 9, "shelf_id": 45, "shelf_number": 2100}	{"rackid": 9, "shelf_id": 45, "shelf_number": 1245}
1180	shelf	UPDATE	46	2025-03-29 22:06:31.687391	{"rackid": 10, "shelf_id": 46, "shelf_number": 1800}	{"rackid": 10, "shelf_id": 46, "shelf_number": 1251}
1181	shelf	UPDATE	47	2025-03-29 22:06:31.687391	{"rackid": 10, "shelf_id": 47, "shelf_number": 1900}	{"rackid": 10, "shelf_id": 47, "shelf_number": 1252}
1182	shelf	UPDATE	48	2025-03-29 22:06:31.687391	{"rackid": 10, "shelf_id": 48, "shelf_number": 2000}	{"rackid": 10, "shelf_id": 48, "shelf_number": 1253}
1183	shelf	UPDATE	49	2025-03-29 22:06:31.687391	{"rackid": 10, "shelf_id": 49, "shelf_number": 2100}	{"rackid": 10, "shelf_id": 49, "shelf_number": 1254}
1184	shelf	UPDATE	50	2025-03-29 22:06:31.687391	{"rackid": 10, "shelf_id": 50, "shelf_number": 2200}	{"rackid": 10, "shelf_id": 50, "shelf_number": 1255}
1185	shelf	UPDATE	51	2025-03-29 22:06:31.687391	{"rackid": 11, "shelf_id": 51, "shelf_number": 1500}	{"rackid": 11, "shelf_id": 51, "shelf_number": 1311}
1186	shelf	UPDATE	52	2025-03-29 22:06:31.687391	{"rackid": 11, "shelf_id": 52, "shelf_number": 1600}	{"rackid": 11, "shelf_id": 52, "shelf_number": 1312}
1187	shelf	UPDATE	53	2025-03-29 22:06:31.687391	{"rackid": 11, "shelf_id": 53, "shelf_number": 1700}	{"rackid": 11, "shelf_id": 53, "shelf_number": 1313}
1188	shelf	UPDATE	54	2025-03-29 22:06:31.687391	{"rackid": 11, "shelf_id": 54, "shelf_number": 1800}	{"rackid": 11, "shelf_id": 54, "shelf_number": 1314}
1189	shelf	UPDATE	55	2025-03-29 22:06:31.687391	{"rackid": 11, "shelf_id": 55, "shelf_number": 1900}	{"rackid": 11, "shelf_id": 55, "shelf_number": 1315}
1190	shelf	UPDATE	56	2025-03-29 22:06:31.687391	{"rackid": 12, "shelf_id": 56, "shelf_number": 1600}	{"rackid": 12, "shelf_id": 56, "shelf_number": 1321}
1191	shelf	UPDATE	57	2025-03-29 22:06:31.687391	{"rackid": 12, "shelf_id": 57, "shelf_number": 1700}	{"rackid": 12, "shelf_id": 57, "shelf_number": 1322}
1192	shelf	UPDATE	58	2025-03-29 22:06:31.687391	{"rackid": 12, "shelf_id": 58, "shelf_number": 1800}	{"rackid": 12, "shelf_id": 58, "shelf_number": 1323}
1193	shelf	UPDATE	59	2025-03-29 22:06:31.687391	{"rackid": 12, "shelf_id": 59, "shelf_number": 1900}	{"rackid": 12, "shelf_id": 59, "shelf_number": 1324}
1194	shelf	UPDATE	60	2025-03-29 22:06:31.687391	{"rackid": 12, "shelf_id": 60, "shelf_number": 2000}	{"rackid": 12, "shelf_id": 60, "shelf_number": 1325}
1195	shelf	UPDATE	61	2025-03-29 22:06:31.687391	{"rackid": 13, "shelf_id": 61, "shelf_number": 1700}	{"rackid": 13, "shelf_id": 61, "shelf_number": 1331}
1196	shelf	UPDATE	62	2025-03-29 22:06:31.687391	{"rackid": 13, "shelf_id": 62, "shelf_number": 1800}	{"rackid": 13, "shelf_id": 62, "shelf_number": 1332}
1197	shelf	UPDATE	63	2025-03-29 22:06:31.687391	{"rackid": 13, "shelf_id": 63, "shelf_number": 1900}	{"rackid": 13, "shelf_id": 63, "shelf_number": 1333}
1198	shelf	UPDATE	64	2025-03-29 22:06:31.687391	{"rackid": 13, "shelf_id": 64, "shelf_number": 2000}	{"rackid": 13, "shelf_id": 64, "shelf_number": 1334}
1199	shelf	UPDATE	65	2025-03-29 22:06:31.687391	{"rackid": 13, "shelf_id": 65, "shelf_number": 2100}	{"rackid": 13, "shelf_id": 65, "shelf_number": 1335}
1200	shelf	UPDATE	66	2025-03-29 22:06:31.687391	{"rackid": 14, "shelf_id": 66, "shelf_number": 1800}	{"rackid": 14, "shelf_id": 66, "shelf_number": 1341}
1201	shelf	UPDATE	67	2025-03-29 22:06:31.687391	{"rackid": 14, "shelf_id": 67, "shelf_number": 1900}	{"rackid": 14, "shelf_id": 67, "shelf_number": 1342}
1202	shelf	UPDATE	68	2025-03-29 22:06:31.687391	{"rackid": 14, "shelf_id": 68, "shelf_number": 2000}	{"rackid": 14, "shelf_id": 68, "shelf_number": 1343}
1203	shelf	UPDATE	69	2025-03-29 22:06:31.687391	{"rackid": 14, "shelf_id": 69, "shelf_number": 2100}	{"rackid": 14, "shelf_id": 69, "shelf_number": 1344}
1204	shelf	UPDATE	70	2025-03-29 22:06:31.687391	{"rackid": 14, "shelf_id": 70, "shelf_number": 2200}	{"rackid": 14, "shelf_id": 70, "shelf_number": 1345}
1205	shelf	UPDATE	71	2025-03-29 22:06:31.687391	{"rackid": 15, "shelf_id": 71, "shelf_number": 1900}	{"rackid": 15, "shelf_id": 71, "shelf_number": 1351}
1206	shelf	UPDATE	72	2025-03-29 22:06:31.687391	{"rackid": 15, "shelf_id": 72, "shelf_number": 2000}	{"rackid": 15, "shelf_id": 72, "shelf_number": 1352}
1207	shelf	UPDATE	73	2025-03-29 22:06:31.687391	{"rackid": 15, "shelf_id": 73, "shelf_number": 2100}	{"rackid": 15, "shelf_id": 73, "shelf_number": 1353}
1208	shelf	UPDATE	74	2025-03-29 22:06:31.687391	{"rackid": 15, "shelf_id": 74, "shelf_number": 2200}	{"rackid": 15, "shelf_id": 74, "shelf_number": 1354}
1209	shelf	UPDATE	75	2025-03-29 22:06:31.687391	{"rackid": 15, "shelf_id": 75, "shelf_number": 2300}	{"rackid": 15, "shelf_id": 75, "shelf_number": 1355}
1210	shelf	UPDATE	76	2025-03-29 22:06:31.687391	{"rackid": 16, "shelf_id": 76, "shelf_number": 1600}	{"rackid": 16, "shelf_id": 76, "shelf_number": 1411}
1211	shelf	UPDATE	77	2025-03-29 22:06:31.687391	{"rackid": 16, "shelf_id": 77, "shelf_number": 1700}	{"rackid": 16, "shelf_id": 77, "shelf_number": 1412}
1212	shelf	UPDATE	78	2025-03-29 22:06:31.687391	{"rackid": 16, "shelf_id": 78, "shelf_number": 1800}	{"rackid": 16, "shelf_id": 78, "shelf_number": 1413}
1213	shelf	UPDATE	79	2025-03-29 22:06:31.687391	{"rackid": 16, "shelf_id": 79, "shelf_number": 1900}	{"rackid": 16, "shelf_id": 79, "shelf_number": 1414}
1214	shelf	UPDATE	80	2025-03-29 22:06:31.687391	{"rackid": 16, "shelf_id": 80, "shelf_number": 2000}	{"rackid": 16, "shelf_id": 80, "shelf_number": 1415}
1215	shelf	UPDATE	81	2025-03-29 22:06:31.687391	{"rackid": 17, "shelf_id": 81, "shelf_number": 1700}	{"rackid": 17, "shelf_id": 81, "shelf_number": 1421}
1216	shelf	UPDATE	82	2025-03-29 22:06:31.687391	{"rackid": 17, "shelf_id": 82, "shelf_number": 1800}	{"rackid": 17, "shelf_id": 82, "shelf_number": 1422}
1217	shelf	UPDATE	83	2025-03-29 22:06:31.687391	{"rackid": 17, "shelf_id": 83, "shelf_number": 1900}	{"rackid": 17, "shelf_id": 83, "shelf_number": 1423}
1218	shelf	UPDATE	84	2025-03-29 22:06:31.687391	{"rackid": 17, "shelf_id": 84, "shelf_number": 2000}	{"rackid": 17, "shelf_id": 84, "shelf_number": 1424}
1219	shelf	UPDATE	85	2025-03-29 22:06:31.687391	{"rackid": 17, "shelf_id": 85, "shelf_number": 2100}	{"rackid": 17, "shelf_id": 85, "shelf_number": 1425}
1220	shelf	UPDATE	86	2025-03-29 22:06:31.687391	{"rackid": 18, "shelf_id": 86, "shelf_number": 1800}	{"rackid": 18, "shelf_id": 86, "shelf_number": 1431}
1221	shelf	UPDATE	87	2025-03-29 22:06:31.687391	{"rackid": 18, "shelf_id": 87, "shelf_number": 1900}	{"rackid": 18, "shelf_id": 87, "shelf_number": 1432}
1222	shelf	UPDATE	88	2025-03-29 22:06:31.687391	{"rackid": 18, "shelf_id": 88, "shelf_number": 2000}	{"rackid": 18, "shelf_id": 88, "shelf_number": 1433}
1223	shelf	UPDATE	89	2025-03-29 22:06:31.687391	{"rackid": 18, "shelf_id": 89, "shelf_number": 2100}	{"rackid": 18, "shelf_id": 89, "shelf_number": 1434}
1224	shelf	UPDATE	90	2025-03-29 22:06:31.687391	{"rackid": 18, "shelf_id": 90, "shelf_number": 2200}	{"rackid": 18, "shelf_id": 90, "shelf_number": 1435}
1225	shelf	UPDATE	91	2025-03-29 22:06:31.687391	{"rackid": 19, "shelf_id": 91, "shelf_number": 1900}	{"rackid": 19, "shelf_id": 91, "shelf_number": 1441}
1226	shelf	UPDATE	92	2025-03-29 22:06:31.687391	{"rackid": 19, "shelf_id": 92, "shelf_number": 2000}	{"rackid": 19, "shelf_id": 92, "shelf_number": 1442}
1227	shelf	UPDATE	93	2025-03-29 22:06:31.687391	{"rackid": 19, "shelf_id": 93, "shelf_number": 2100}	{"rackid": 19, "shelf_id": 93, "shelf_number": 1443}
1228	shelf	UPDATE	94	2025-03-29 22:06:31.687391	{"rackid": 19, "shelf_id": 94, "shelf_number": 2200}	{"rackid": 19, "shelf_id": 94, "shelf_number": 1444}
1229	shelf	UPDATE	95	2025-03-29 22:06:31.687391	{"rackid": 19, "shelf_id": 95, "shelf_number": 2300}	{"rackid": 19, "shelf_id": 95, "shelf_number": 1445}
1230	shelf	UPDATE	96	2025-03-29 22:06:31.687391	{"rackid": 20, "shelf_id": 96, "shelf_number": 2000}	{"rackid": 20, "shelf_id": 96, "shelf_number": 1451}
1231	shelf	UPDATE	97	2025-03-29 22:06:31.687391	{"rackid": 20, "shelf_id": 97, "shelf_number": 2100}	{"rackid": 20, "shelf_id": 97, "shelf_number": 1452}
1232	shelf	UPDATE	98	2025-03-29 22:06:31.687391	{"rackid": 20, "shelf_id": 98, "shelf_number": 2200}	{"rackid": 20, "shelf_id": 98, "shelf_number": 1453}
1233	shelf	UPDATE	99	2025-03-29 22:06:31.687391	{"rackid": 20, "shelf_id": 99, "shelf_number": 2300}	{"rackid": 20, "shelf_id": 99, "shelf_number": 1454}
1234	shelf	UPDATE	100	2025-03-29 22:06:31.687391	{"rackid": 20, "shelf_id": 100, "shelf_number": 2400}	{"rackid": 20, "shelf_id": 100, "shelf_number": 1455}
1235	shelf	UPDATE	101	2025-03-29 22:06:31.687391	{"rackid": 21, "shelf_id": 101, "shelf_number": 1700}	{"rackid": 21, "shelf_id": 101, "shelf_number": 1511}
1236	shelf	UPDATE	102	2025-03-29 22:06:31.687391	{"rackid": 21, "shelf_id": 102, "shelf_number": 1800}	{"rackid": 21, "shelf_id": 102, "shelf_number": 1512}
1237	shelf	UPDATE	103	2025-03-29 22:06:31.687391	{"rackid": 21, "shelf_id": 103, "shelf_number": 1900}	{"rackid": 21, "shelf_id": 103, "shelf_number": 1513}
1238	shelf	UPDATE	104	2025-03-29 22:06:31.687391	{"rackid": 21, "shelf_id": 104, "shelf_number": 2000}	{"rackid": 21, "shelf_id": 104, "shelf_number": 1514}
1239	shelf	UPDATE	105	2025-03-29 22:06:31.687391	{"rackid": 21, "shelf_id": 105, "shelf_number": 2100}	{"rackid": 21, "shelf_id": 105, "shelf_number": 1515}
1240	shelf	UPDATE	106	2025-03-29 22:06:31.687391	{"rackid": 22, "shelf_id": 106, "shelf_number": 1800}	{"rackid": 22, "shelf_id": 106, "shelf_number": 1521}
1241	shelf	UPDATE	107	2025-03-29 22:06:31.687391	{"rackid": 22, "shelf_id": 107, "shelf_number": 1900}	{"rackid": 22, "shelf_id": 107, "shelf_number": 1522}
1242	shelf	UPDATE	108	2025-03-29 22:06:31.687391	{"rackid": 22, "shelf_id": 108, "shelf_number": 2000}	{"rackid": 22, "shelf_id": 108, "shelf_number": 1523}
1243	shelf	UPDATE	109	2025-03-29 22:06:31.687391	{"rackid": 22, "shelf_id": 109, "shelf_number": 2100}	{"rackid": 22, "shelf_id": 109, "shelf_number": 1524}
1244	shelf	UPDATE	110	2025-03-29 22:06:31.687391	{"rackid": 22, "shelf_id": 110, "shelf_number": 2200}	{"rackid": 22, "shelf_id": 110, "shelf_number": 1525}
1245	shelf	UPDATE	111	2025-03-29 22:06:31.687391	{"rackid": 23, "shelf_id": 111, "shelf_number": 1900}	{"rackid": 23, "shelf_id": 111, "shelf_number": 1531}
1246	shelf	UPDATE	112	2025-03-29 22:06:31.687391	{"rackid": 23, "shelf_id": 112, "shelf_number": 2000}	{"rackid": 23, "shelf_id": 112, "shelf_number": 1532}
1247	shelf	UPDATE	113	2025-03-29 22:06:31.687391	{"rackid": 23, "shelf_id": 113, "shelf_number": 2100}	{"rackid": 23, "shelf_id": 113, "shelf_number": 1533}
1248	shelf	UPDATE	114	2025-03-29 22:06:31.687391	{"rackid": 23, "shelf_id": 114, "shelf_number": 2200}	{"rackid": 23, "shelf_id": 114, "shelf_number": 1534}
1249	shelf	UPDATE	115	2025-03-29 22:06:31.687391	{"rackid": 23, "shelf_id": 115, "shelf_number": 2300}	{"rackid": 23, "shelf_id": 115, "shelf_number": 1535}
1250	shelf	UPDATE	116	2025-03-29 22:06:31.687391	{"rackid": 24, "shelf_id": 116, "shelf_number": 2000}	{"rackid": 24, "shelf_id": 116, "shelf_number": 1541}
1251	shelf	UPDATE	117	2025-03-29 22:06:31.687391	{"rackid": 24, "shelf_id": 117, "shelf_number": 2100}	{"rackid": 24, "shelf_id": 117, "shelf_number": 1542}
1252	shelf	UPDATE	118	2025-03-29 22:06:31.687391	{"rackid": 24, "shelf_id": 118, "shelf_number": 2200}	{"rackid": 24, "shelf_id": 118, "shelf_number": 1543}
1253	shelf	UPDATE	119	2025-03-29 22:06:31.687391	{"rackid": 24, "shelf_id": 119, "shelf_number": 2300}	{"rackid": 24, "shelf_id": 119, "shelf_number": 1544}
1254	shelf	UPDATE	120	2025-03-29 22:06:31.687391	{"rackid": 24, "shelf_id": 120, "shelf_number": 2400}	{"rackid": 24, "shelf_id": 120, "shelf_number": 1545}
1255	shelf	UPDATE	121	2025-03-29 22:06:31.687391	{"rackid": 25, "shelf_id": 121, "shelf_number": 2100}	{"rackid": 25, "shelf_id": 121, "shelf_number": 1551}
1256	shelf	UPDATE	122	2025-03-29 22:06:31.687391	{"rackid": 25, "shelf_id": 122, "shelf_number": 2200}	{"rackid": 25, "shelf_id": 122, "shelf_number": 1552}
1257	shelf	UPDATE	123	2025-03-29 22:06:31.687391	{"rackid": 25, "shelf_id": 123, "shelf_number": 2300}	{"rackid": 25, "shelf_id": 123, "shelf_number": 1553}
1258	shelf	UPDATE	124	2025-03-29 22:06:31.687391	{"rackid": 25, "shelf_id": 124, "shelf_number": 2400}	{"rackid": 25, "shelf_id": 124, "shelf_number": 1554}
1259	shelf	UPDATE	125	2025-03-29 22:06:31.687391	{"rackid": 25, "shelf_id": 125, "shelf_number": 2500}	{"rackid": 25, "shelf_id": 125, "shelf_number": 1555}
1260	shelf	UPDATE	126	2025-03-29 22:06:31.687391	{"rackid": 26, "shelf_id": 126, "shelf_number": 2300}	{"rackid": 26, "shelf_id": 126, "shelf_number": 2111}
1261	shelf	UPDATE	127	2025-03-29 22:06:31.687391	{"rackid": 26, "shelf_id": 127, "shelf_number": 2400}	{"rackid": 26, "shelf_id": 127, "shelf_number": 2112}
1262	shelf	UPDATE	128	2025-03-29 22:06:31.687391	{"rackid": 26, "shelf_id": 128, "shelf_number": 2500}	{"rackid": 26, "shelf_id": 128, "shelf_number": 2113}
1263	shelf	UPDATE	129	2025-03-29 22:06:31.687391	{"rackid": 26, "shelf_id": 129, "shelf_number": 2600}	{"rackid": 26, "shelf_id": 129, "shelf_number": 2114}
1264	shelf	UPDATE	130	2025-03-29 22:06:31.687391	{"rackid": 26, "shelf_id": 130, "shelf_number": 2700}	{"rackid": 26, "shelf_id": 130, "shelf_number": 2115}
1265	shelf	UPDATE	131	2025-03-29 22:06:31.687391	{"rackid": 27, "shelf_id": 131, "shelf_number": 2400}	{"rackid": 27, "shelf_id": 131, "shelf_number": 2121}
1266	shelf	UPDATE	132	2025-03-29 22:06:31.687391	{"rackid": 27, "shelf_id": 132, "shelf_number": 2500}	{"rackid": 27, "shelf_id": 132, "shelf_number": 2122}
1267	shelf	UPDATE	133	2025-03-29 22:06:31.687391	{"rackid": 27, "shelf_id": 133, "shelf_number": 2600}	{"rackid": 27, "shelf_id": 133, "shelf_number": 2123}
1268	shelf	UPDATE	134	2025-03-29 22:06:31.687391	{"rackid": 27, "shelf_id": 134, "shelf_number": 2700}	{"rackid": 27, "shelf_id": 134, "shelf_number": 2124}
1269	shelf	UPDATE	135	2025-03-29 22:06:31.687391	{"rackid": 27, "shelf_id": 135, "shelf_number": 2800}	{"rackid": 27, "shelf_id": 135, "shelf_number": 2125}
1270	shelf	UPDATE	136	2025-03-29 22:06:31.687391	{"rackid": 28, "shelf_id": 136, "shelf_number": 2500}	{"rackid": 28, "shelf_id": 136, "shelf_number": 2131}
1271	shelf	UPDATE	137	2025-03-29 22:06:31.687391	{"rackid": 28, "shelf_id": 137, "shelf_number": 2600}	{"rackid": 28, "shelf_id": 137, "shelf_number": 2132}
1272	shelf	UPDATE	138	2025-03-29 22:06:31.687391	{"rackid": 28, "shelf_id": 138, "shelf_number": 2700}	{"rackid": 28, "shelf_id": 138, "shelf_number": 2133}
1273	shelf	UPDATE	139	2025-03-29 22:06:31.687391	{"rackid": 28, "shelf_id": 139, "shelf_number": 2800}	{"rackid": 28, "shelf_id": 139, "shelf_number": 2134}
1274	shelf	UPDATE	140	2025-03-29 22:06:31.687391	{"rackid": 28, "shelf_id": 140, "shelf_number": 2900}	{"rackid": 28, "shelf_id": 140, "shelf_number": 2135}
1275	shelf	UPDATE	141	2025-03-29 22:06:31.687391	{"rackid": 29, "shelf_id": 141, "shelf_number": 2600}	{"rackid": 29, "shelf_id": 141, "shelf_number": 2141}
1276	shelf	UPDATE	142	2025-03-29 22:06:31.687391	{"rackid": 29, "shelf_id": 142, "shelf_number": 2700}	{"rackid": 29, "shelf_id": 142, "shelf_number": 2142}
1277	shelf	UPDATE	143	2025-03-29 22:06:31.687391	{"rackid": 29, "shelf_id": 143, "shelf_number": 2800}	{"rackid": 29, "shelf_id": 143, "shelf_number": 2143}
1278	shelf	UPDATE	144	2025-03-29 22:06:31.687391	{"rackid": 29, "shelf_id": 144, "shelf_number": 2900}	{"rackid": 29, "shelf_id": 144, "shelf_number": 2144}
1279	shelf	UPDATE	145	2025-03-29 22:06:31.687391	{"rackid": 29, "shelf_id": 145, "shelf_number": 3000}	{"rackid": 29, "shelf_id": 145, "shelf_number": 2145}
1280	shelf	UPDATE	146	2025-03-29 22:06:31.687391	{"rackid": 30, "shelf_id": 146, "shelf_number": 2700}	{"rackid": 30, "shelf_id": 146, "shelf_number": 2151}
1281	shelf	UPDATE	147	2025-03-29 22:06:31.687391	{"rackid": 30, "shelf_id": 147, "shelf_number": 2800}	{"rackid": 30, "shelf_id": 147, "shelf_number": 2152}
1282	shelf	UPDATE	148	2025-03-29 22:06:31.687391	{"rackid": 30, "shelf_id": 148, "shelf_number": 2900}	{"rackid": 30, "shelf_id": 148, "shelf_number": 2153}
1283	shelf	UPDATE	149	2025-03-29 22:06:31.687391	{"rackid": 30, "shelf_id": 149, "shelf_number": 3000}	{"rackid": 30, "shelf_id": 149, "shelf_number": 2154}
1284	shelf	UPDATE	150	2025-03-29 22:06:31.687391	{"rackid": 30, "shelf_id": 150, "shelf_number": 3100}	{"rackid": 30, "shelf_id": 150, "shelf_number": 2155}
1285	shelf	UPDATE	151	2025-03-29 22:06:31.687391	{"rackid": 31, "shelf_id": 151, "shelf_number": 2400}	{"rackid": 31, "shelf_id": 151, "shelf_number": 2211}
1286	shelf	UPDATE	152	2025-03-29 22:06:31.687391	{"rackid": 31, "shelf_id": 152, "shelf_number": 2500}	{"rackid": 31, "shelf_id": 152, "shelf_number": 2212}
1287	shelf	UPDATE	153	2025-03-29 22:06:31.687391	{"rackid": 31, "shelf_id": 153, "shelf_number": 2600}	{"rackid": 31, "shelf_id": 153, "shelf_number": 2213}
1288	shelf	UPDATE	154	2025-03-29 22:06:31.687391	{"rackid": 31, "shelf_id": 154, "shelf_number": 2700}	{"rackid": 31, "shelf_id": 154, "shelf_number": 2214}
1289	shelf	UPDATE	155	2025-03-29 22:06:31.687391	{"rackid": 31, "shelf_id": 155, "shelf_number": 2800}	{"rackid": 31, "shelf_id": 155, "shelf_number": 2215}
1290	shelf	UPDATE	156	2025-03-29 22:06:31.687391	{"rackid": 32, "shelf_id": 156, "shelf_number": 2500}	{"rackid": 32, "shelf_id": 156, "shelf_number": 2221}
1291	shelf	UPDATE	157	2025-03-29 22:06:31.687391	{"rackid": 32, "shelf_id": 157, "shelf_number": 2600}	{"rackid": 32, "shelf_id": 157, "shelf_number": 2222}
1292	shelf	UPDATE	158	2025-03-29 22:06:31.687391	{"rackid": 32, "shelf_id": 158, "shelf_number": 2700}	{"rackid": 32, "shelf_id": 158, "shelf_number": 2223}
1293	shelf	UPDATE	159	2025-03-29 22:06:31.687391	{"rackid": 32, "shelf_id": 159, "shelf_number": 2800}	{"rackid": 32, "shelf_id": 159, "shelf_number": 2224}
1294	shelf	UPDATE	160	2025-03-29 22:06:31.687391	{"rackid": 32, "shelf_id": 160, "shelf_number": 2900}	{"rackid": 32, "shelf_id": 160, "shelf_number": 2225}
1295	shelf	UPDATE	161	2025-03-29 22:06:31.687391	{"rackid": 33, "shelf_id": 161, "shelf_number": 2600}	{"rackid": 33, "shelf_id": 161, "shelf_number": 2231}
1296	shelf	UPDATE	162	2025-03-29 22:06:31.687391	{"rackid": 33, "shelf_id": 162, "shelf_number": 2700}	{"rackid": 33, "shelf_id": 162, "shelf_number": 2232}
1297	shelf	UPDATE	163	2025-03-29 22:06:31.687391	{"rackid": 33, "shelf_id": 163, "shelf_number": 2800}	{"rackid": 33, "shelf_id": 163, "shelf_number": 2233}
1298	shelf	UPDATE	164	2025-03-29 22:06:31.687391	{"rackid": 33, "shelf_id": 164, "shelf_number": 2900}	{"rackid": 33, "shelf_id": 164, "shelf_number": 2234}
1299	shelf	UPDATE	165	2025-03-29 22:06:31.687391	{"rackid": 33, "shelf_id": 165, "shelf_number": 3000}	{"rackid": 33, "shelf_id": 165, "shelf_number": 2235}
1300	shelf	UPDATE	166	2025-03-29 22:06:31.687391	{"rackid": 34, "shelf_id": 166, "shelf_number": 2700}	{"rackid": 34, "shelf_id": 166, "shelf_number": 2241}
1301	shelf	UPDATE	167	2025-03-29 22:06:31.687391	{"rackid": 34, "shelf_id": 167, "shelf_number": 2800}	{"rackid": 34, "shelf_id": 167, "shelf_number": 2242}
1302	shelf	UPDATE	168	2025-03-29 22:06:31.687391	{"rackid": 34, "shelf_id": 168, "shelf_number": 2900}	{"rackid": 34, "shelf_id": 168, "shelf_number": 2243}
1303	shelf	UPDATE	169	2025-03-29 22:06:31.687391	{"rackid": 34, "shelf_id": 169, "shelf_number": 3000}	{"rackid": 34, "shelf_id": 169, "shelf_number": 2244}
1304	shelf	UPDATE	170	2025-03-29 22:06:31.687391	{"rackid": 34, "shelf_id": 170, "shelf_number": 3100}	{"rackid": 34, "shelf_id": 170, "shelf_number": 2245}
1305	shelf	UPDATE	171	2025-03-29 22:06:31.687391	{"rackid": 35, "shelf_id": 171, "shelf_number": 2800}	{"rackid": 35, "shelf_id": 171, "shelf_number": 2251}
1306	shelf	UPDATE	172	2025-03-29 22:06:31.687391	{"rackid": 35, "shelf_id": 172, "shelf_number": 2900}	{"rackid": 35, "shelf_id": 172, "shelf_number": 2252}
1307	shelf	UPDATE	173	2025-03-29 22:06:31.687391	{"rackid": 35, "shelf_id": 173, "shelf_number": 3000}	{"rackid": 35, "shelf_id": 173, "shelf_number": 2253}
1308	shelf	UPDATE	174	2025-03-29 22:06:31.687391	{"rackid": 35, "shelf_id": 174, "shelf_number": 3100}	{"rackid": 35, "shelf_id": 174, "shelf_number": 2254}
1309	shelf	UPDATE	175	2025-03-29 22:06:31.687391	{"rackid": 35, "shelf_id": 175, "shelf_number": 3200}	{"rackid": 35, "shelf_id": 175, "shelf_number": 2255}
1310	shelf	UPDATE	176	2025-03-29 22:06:31.687391	{"rackid": 36, "shelf_id": 176, "shelf_number": 2500}	{"rackid": 36, "shelf_id": 176, "shelf_number": 2311}
1311	shelf	UPDATE	177	2025-03-29 22:06:31.687391	{"rackid": 36, "shelf_id": 177, "shelf_number": 2600}	{"rackid": 36, "shelf_id": 177, "shelf_number": 2312}
1312	shelf	UPDATE	178	2025-03-29 22:06:31.687391	{"rackid": 36, "shelf_id": 178, "shelf_number": 2700}	{"rackid": 36, "shelf_id": 178, "shelf_number": 2313}
1313	shelf	UPDATE	179	2025-03-29 22:06:31.687391	{"rackid": 36, "shelf_id": 179, "shelf_number": 2800}	{"rackid": 36, "shelf_id": 179, "shelf_number": 2314}
1314	shelf	UPDATE	180	2025-03-29 22:06:31.687391	{"rackid": 36, "shelf_id": 180, "shelf_number": 2900}	{"rackid": 36, "shelf_id": 180, "shelf_number": 2315}
1315	shelf	UPDATE	181	2025-03-29 22:06:31.687391	{"rackid": 37, "shelf_id": 181, "shelf_number": 2600}	{"rackid": 37, "shelf_id": 181, "shelf_number": 2321}
1316	shelf	UPDATE	182	2025-03-29 22:06:31.687391	{"rackid": 37, "shelf_id": 182, "shelf_number": 2700}	{"rackid": 37, "shelf_id": 182, "shelf_number": 2322}
1317	shelf	UPDATE	183	2025-03-29 22:06:31.687391	{"rackid": 37, "shelf_id": 183, "shelf_number": 2800}	{"rackid": 37, "shelf_id": 183, "shelf_number": 2323}
1318	shelf	UPDATE	184	2025-03-29 22:06:31.687391	{"rackid": 37, "shelf_id": 184, "shelf_number": 2900}	{"rackid": 37, "shelf_id": 184, "shelf_number": 2324}
1319	shelf	UPDATE	185	2025-03-29 22:06:31.687391	{"rackid": 37, "shelf_id": 185, "shelf_number": 3000}	{"rackid": 37, "shelf_id": 185, "shelf_number": 2325}
1320	shelf	UPDATE	186	2025-03-29 22:06:31.687391	{"rackid": 38, "shelf_id": 186, "shelf_number": 2700}	{"rackid": 38, "shelf_id": 186, "shelf_number": 2331}
1321	shelf	UPDATE	187	2025-03-29 22:06:31.687391	{"rackid": 38, "shelf_id": 187, "shelf_number": 2800}	{"rackid": 38, "shelf_id": 187, "shelf_number": 2332}
1322	shelf	UPDATE	188	2025-03-29 22:06:31.687391	{"rackid": 38, "shelf_id": 188, "shelf_number": 2900}	{"rackid": 38, "shelf_id": 188, "shelf_number": 2333}
1323	shelf	UPDATE	189	2025-03-29 22:06:31.687391	{"rackid": 38, "shelf_id": 189, "shelf_number": 3000}	{"rackid": 38, "shelf_id": 189, "shelf_number": 2334}
1324	shelf	UPDATE	190	2025-03-29 22:06:31.687391	{"rackid": 38, "shelf_id": 190, "shelf_number": 3100}	{"rackid": 38, "shelf_id": 190, "shelf_number": 2335}
1325	shelf	UPDATE	191	2025-03-29 22:06:31.687391	{"rackid": 39, "shelf_id": 191, "shelf_number": 2800}	{"rackid": 39, "shelf_id": 191, "shelf_number": 2341}
1326	shelf	UPDATE	192	2025-03-29 22:06:31.687391	{"rackid": 39, "shelf_id": 192, "shelf_number": 2900}	{"rackid": 39, "shelf_id": 192, "shelf_number": 2342}
1327	shelf	UPDATE	193	2025-03-29 22:06:31.687391	{"rackid": 39, "shelf_id": 193, "shelf_number": 3000}	{"rackid": 39, "shelf_id": 193, "shelf_number": 2343}
1328	shelf	UPDATE	194	2025-03-29 22:06:31.687391	{"rackid": 39, "shelf_id": 194, "shelf_number": 3100}	{"rackid": 39, "shelf_id": 194, "shelf_number": 2344}
1329	shelf	UPDATE	195	2025-03-29 22:06:31.687391	{"rackid": 39, "shelf_id": 195, "shelf_number": 3200}	{"rackid": 39, "shelf_id": 195, "shelf_number": 2345}
1330	shelf	UPDATE	196	2025-03-29 22:06:31.687391	{"rackid": 40, "shelf_id": 196, "shelf_number": 2900}	{"rackid": 40, "shelf_id": 196, "shelf_number": 2351}
1331	shelf	UPDATE	197	2025-03-29 22:06:31.687391	{"rackid": 40, "shelf_id": 197, "shelf_number": 3000}	{"rackid": 40, "shelf_id": 197, "shelf_number": 2352}
1332	shelf	UPDATE	198	2025-03-29 22:06:31.687391	{"rackid": 40, "shelf_id": 198, "shelf_number": 3100}	{"rackid": 40, "shelf_id": 198, "shelf_number": 2353}
1333	shelf	UPDATE	199	2025-03-29 22:06:31.687391	{"rackid": 40, "shelf_id": 199, "shelf_number": 3200}	{"rackid": 40, "shelf_id": 199, "shelf_number": 2354}
1334	shelf	UPDATE	200	2025-03-29 22:06:31.687391	{"rackid": 40, "shelf_id": 200, "shelf_number": 3300}	{"rackid": 40, "shelf_id": 200, "shelf_number": 2355}
1335	shelf	UPDATE	201	2025-03-29 22:06:31.687391	{"rackid": 41, "shelf_id": 201, "shelf_number": 2600}	{"rackid": 41, "shelf_id": 201, "shelf_number": 2411}
1336	shelf	UPDATE	202	2025-03-29 22:06:31.687391	{"rackid": 41, "shelf_id": 202, "shelf_number": 2700}	{"rackid": 41, "shelf_id": 202, "shelf_number": 2412}
1337	shelf	UPDATE	203	2025-03-29 22:06:31.687391	{"rackid": 41, "shelf_id": 203, "shelf_number": 2800}	{"rackid": 41, "shelf_id": 203, "shelf_number": 2413}
1338	shelf	UPDATE	204	2025-03-29 22:06:31.687391	{"rackid": 41, "shelf_id": 204, "shelf_number": 2900}	{"rackid": 41, "shelf_id": 204, "shelf_number": 2414}
1339	shelf	UPDATE	205	2025-03-29 22:06:31.687391	{"rackid": 41, "shelf_id": 205, "shelf_number": 3000}	{"rackid": 41, "shelf_id": 205, "shelf_number": 2415}
1340	shelf	UPDATE	206	2025-03-29 22:06:31.687391	{"rackid": 42, "shelf_id": 206, "shelf_number": 2700}	{"rackid": 42, "shelf_id": 206, "shelf_number": 2421}
1341	shelf	UPDATE	207	2025-03-29 22:06:31.687391	{"rackid": 42, "shelf_id": 207, "shelf_number": 2800}	{"rackid": 42, "shelf_id": 207, "shelf_number": 2422}
1342	shelf	UPDATE	208	2025-03-29 22:06:31.687391	{"rackid": 42, "shelf_id": 208, "shelf_number": 2900}	{"rackid": 42, "shelf_id": 208, "shelf_number": 2423}
1343	shelf	UPDATE	209	2025-03-29 22:06:31.687391	{"rackid": 42, "shelf_id": 209, "shelf_number": 3000}	{"rackid": 42, "shelf_id": 209, "shelf_number": 2424}
1344	shelf	UPDATE	210	2025-03-29 22:06:31.687391	{"rackid": 42, "shelf_id": 210, "shelf_number": 3100}	{"rackid": 42, "shelf_id": 210, "shelf_number": 2425}
1345	shelf	UPDATE	211	2025-03-29 22:06:31.687391	{"rackid": 43, "shelf_id": 211, "shelf_number": 2800}	{"rackid": 43, "shelf_id": 211, "shelf_number": 2431}
1346	shelf	UPDATE	212	2025-03-29 22:06:31.687391	{"rackid": 43, "shelf_id": 212, "shelf_number": 2900}	{"rackid": 43, "shelf_id": 212, "shelf_number": 2432}
1347	shelf	UPDATE	213	2025-03-29 22:06:31.687391	{"rackid": 43, "shelf_id": 213, "shelf_number": 3000}	{"rackid": 43, "shelf_id": 213, "shelf_number": 2433}
1348	shelf	UPDATE	214	2025-03-29 22:06:31.687391	{"rackid": 43, "shelf_id": 214, "shelf_number": 3100}	{"rackid": 43, "shelf_id": 214, "shelf_number": 2434}
1349	shelf	UPDATE	215	2025-03-29 22:06:31.687391	{"rackid": 43, "shelf_id": 215, "shelf_number": 3200}	{"rackid": 43, "shelf_id": 215, "shelf_number": 2435}
1350	shelf	UPDATE	216	2025-03-29 22:06:31.687391	{"rackid": 44, "shelf_id": 216, "shelf_number": 2900}	{"rackid": 44, "shelf_id": 216, "shelf_number": 2441}
1351	shelf	UPDATE	217	2025-03-29 22:06:31.687391	{"rackid": 44, "shelf_id": 217, "shelf_number": 3000}	{"rackid": 44, "shelf_id": 217, "shelf_number": 2442}
1352	shelf	UPDATE	218	2025-03-29 22:06:31.687391	{"rackid": 44, "shelf_id": 218, "shelf_number": 3100}	{"rackid": 44, "shelf_id": 218, "shelf_number": 2443}
1353	shelf	UPDATE	219	2025-03-29 22:06:31.687391	{"rackid": 44, "shelf_id": 219, "shelf_number": 3200}	{"rackid": 44, "shelf_id": 219, "shelf_number": 2444}
1354	shelf	UPDATE	220	2025-03-29 22:06:31.687391	{"rackid": 44, "shelf_id": 220, "shelf_number": 3300}	{"rackid": 44, "shelf_id": 220, "shelf_number": 2445}
1355	shelf	UPDATE	221	2025-03-29 22:06:31.687391	{"rackid": 45, "shelf_id": 221, "shelf_number": 3000}	{"rackid": 45, "shelf_id": 221, "shelf_number": 2451}
1356	shelf	UPDATE	222	2025-03-29 22:06:31.687391	{"rackid": 45, "shelf_id": 222, "shelf_number": 3100}	{"rackid": 45, "shelf_id": 222, "shelf_number": 2452}
1357	shelf	UPDATE	223	2025-03-29 22:06:31.687391	{"rackid": 45, "shelf_id": 223, "shelf_number": 3200}	{"rackid": 45, "shelf_id": 223, "shelf_number": 2453}
1358	shelf	UPDATE	224	2025-03-29 22:06:31.687391	{"rackid": 45, "shelf_id": 224, "shelf_number": 3300}	{"rackid": 45, "shelf_id": 224, "shelf_number": 2454}
1359	shelf	UPDATE	225	2025-03-29 22:06:31.687391	{"rackid": 45, "shelf_id": 225, "shelf_number": 3400}	{"rackid": 45, "shelf_id": 225, "shelf_number": 2455}
1360	shelf	UPDATE	226	2025-03-29 22:06:31.687391	{"rackid": 46, "shelf_id": 226, "shelf_number": 2700}	{"rackid": 46, "shelf_id": 226, "shelf_number": 2511}
1361	shelf	UPDATE	227	2025-03-29 22:06:31.687391	{"rackid": 46, "shelf_id": 227, "shelf_number": 2800}	{"rackid": 46, "shelf_id": 227, "shelf_number": 2512}
1362	shelf	UPDATE	228	2025-03-29 22:06:31.687391	{"rackid": 46, "shelf_id": 228, "shelf_number": 2900}	{"rackid": 46, "shelf_id": 228, "shelf_number": 2513}
1363	shelf	UPDATE	229	2025-03-29 22:06:31.687391	{"rackid": 46, "shelf_id": 229, "shelf_number": 3000}	{"rackid": 46, "shelf_id": 229, "shelf_number": 2514}
1364	shelf	UPDATE	230	2025-03-29 22:06:31.687391	{"rackid": 46, "shelf_id": 230, "shelf_number": 3100}	{"rackid": 46, "shelf_id": 230, "shelf_number": 2515}
1365	shelf	UPDATE	231	2025-03-29 22:06:31.687391	{"rackid": 47, "shelf_id": 231, "shelf_number": 2800}	{"rackid": 47, "shelf_id": 231, "shelf_number": 2521}
1366	shelf	UPDATE	232	2025-03-29 22:06:31.687391	{"rackid": 47, "shelf_id": 232, "shelf_number": 2900}	{"rackid": 47, "shelf_id": 232, "shelf_number": 2522}
1367	shelf	UPDATE	233	2025-03-29 22:06:31.687391	{"rackid": 47, "shelf_id": 233, "shelf_number": 3000}	{"rackid": 47, "shelf_id": 233, "shelf_number": 2523}
1368	shelf	UPDATE	234	2025-03-29 22:06:31.687391	{"rackid": 47, "shelf_id": 234, "shelf_number": 3100}	{"rackid": 47, "shelf_id": 234, "shelf_number": 2524}
1369	shelf	UPDATE	235	2025-03-29 22:06:31.687391	{"rackid": 47, "shelf_id": 235, "shelf_number": 3200}	{"rackid": 47, "shelf_id": 235, "shelf_number": 2525}
1370	shelf	UPDATE	236	2025-03-29 22:06:31.687391	{"rackid": 48, "shelf_id": 236, "shelf_number": 2900}	{"rackid": 48, "shelf_id": 236, "shelf_number": 2531}
1371	shelf	UPDATE	237	2025-03-29 22:06:31.687391	{"rackid": 48, "shelf_id": 237, "shelf_number": 3000}	{"rackid": 48, "shelf_id": 237, "shelf_number": 2532}
1372	shelf	UPDATE	238	2025-03-29 22:06:31.687391	{"rackid": 48, "shelf_id": 238, "shelf_number": 3100}	{"rackid": 48, "shelf_id": 238, "shelf_number": 2533}
1373	shelf	UPDATE	239	2025-03-29 22:06:31.687391	{"rackid": 48, "shelf_id": 239, "shelf_number": 3200}	{"rackid": 48, "shelf_id": 239, "shelf_number": 2534}
1374	shelf	UPDATE	240	2025-03-29 22:06:31.687391	{"rackid": 48, "shelf_id": 240, "shelf_number": 3300}	{"rackid": 48, "shelf_id": 240, "shelf_number": 2535}
1375	shelf	UPDATE	241	2025-03-29 22:06:31.687391	{"rackid": 49, "shelf_id": 241, "shelf_number": 3000}	{"rackid": 49, "shelf_id": 241, "shelf_number": 2541}
1376	shelf	UPDATE	242	2025-03-29 22:06:31.687391	{"rackid": 49, "shelf_id": 242, "shelf_number": 3100}	{"rackid": 49, "shelf_id": 242, "shelf_number": 2542}
1377	shelf	UPDATE	243	2025-03-29 22:06:31.687391	{"rackid": 49, "shelf_id": 243, "shelf_number": 3200}	{"rackid": 49, "shelf_id": 243, "shelf_number": 2543}
1378	shelf	UPDATE	244	2025-03-29 22:06:31.687391	{"rackid": 49, "shelf_id": 244, "shelf_number": 3300}	{"rackid": 49, "shelf_id": 244, "shelf_number": 2544}
1379	shelf	UPDATE	245	2025-03-29 22:06:31.687391	{"rackid": 49, "shelf_id": 245, "shelf_number": 3400}	{"rackid": 49, "shelf_id": 245, "shelf_number": 2545}
1380	shelf	UPDATE	246	2025-03-29 22:06:31.687391	{"rackid": 50, "shelf_id": 246, "shelf_number": 3100}	{"rackid": 50, "shelf_id": 246, "shelf_number": 2551}
1381	shelf	UPDATE	247	2025-03-29 22:06:31.687391	{"rackid": 50, "shelf_id": 247, "shelf_number": 3200}	{"rackid": 50, "shelf_id": 247, "shelf_number": 2552}
1382	shelf	UPDATE	248	2025-03-29 22:06:31.687391	{"rackid": 50, "shelf_id": 248, "shelf_number": 3300}	{"rackid": 50, "shelf_id": 248, "shelf_number": 2553}
1383	shelf	UPDATE	249	2025-03-29 22:06:31.687391	{"rackid": 50, "shelf_id": 249, "shelf_number": 3400}	{"rackid": 50, "shelf_id": 249, "shelf_number": 2554}
1384	shelf	UPDATE	250	2025-03-29 22:06:31.687391	{"rackid": 50, "shelf_id": 250, "shelf_number": 3500}	{"rackid": 50, "shelf_id": 250, "shelf_number": 2555}
1385	shelf	UPDATE	251	2025-03-29 22:06:31.687391	{"rackid": 51, "shelf_id": 251, "shelf_number": 3300}	{"rackid": 51, "shelf_id": 251, "shelf_number": 3111}
1386	shelf	UPDATE	252	2025-03-29 22:06:31.687391	{"rackid": 51, "shelf_id": 252, "shelf_number": 3400}	{"rackid": 51, "shelf_id": 252, "shelf_number": 3112}
1387	shelf	UPDATE	253	2025-03-29 22:06:31.687391	{"rackid": 51, "shelf_id": 253, "shelf_number": 3500}	{"rackid": 51, "shelf_id": 253, "shelf_number": 3113}
1388	shelf	UPDATE	254	2025-03-29 22:06:31.687391	{"rackid": 51, "shelf_id": 254, "shelf_number": 3600}	{"rackid": 51, "shelf_id": 254, "shelf_number": 3114}
1389	shelf	UPDATE	255	2025-03-29 22:06:31.687391	{"rackid": 51, "shelf_id": 255, "shelf_number": 3700}	{"rackid": 51, "shelf_id": 255, "shelf_number": 3115}
1390	shelf	UPDATE	256	2025-03-29 22:06:31.687391	{"rackid": 52, "shelf_id": 256, "shelf_number": 3400}	{"rackid": 52, "shelf_id": 256, "shelf_number": 3121}
1391	shelf	UPDATE	257	2025-03-29 22:06:31.687391	{"rackid": 52, "shelf_id": 257, "shelf_number": 3500}	{"rackid": 52, "shelf_id": 257, "shelf_number": 3122}
1392	shelf	UPDATE	258	2025-03-29 22:06:31.687391	{"rackid": 52, "shelf_id": 258, "shelf_number": 3600}	{"rackid": 52, "shelf_id": 258, "shelf_number": 3123}
1393	shelf	UPDATE	259	2025-03-29 22:06:31.687391	{"rackid": 52, "shelf_id": 259, "shelf_number": 3700}	{"rackid": 52, "shelf_id": 259, "shelf_number": 3124}
1394	shelf	UPDATE	260	2025-03-29 22:06:31.687391	{"rackid": 52, "shelf_id": 260, "shelf_number": 3800}	{"rackid": 52, "shelf_id": 260, "shelf_number": 3125}
1395	shelf	UPDATE	261	2025-03-29 22:06:31.687391	{"rackid": 53, "shelf_id": 261, "shelf_number": 3500}	{"rackid": 53, "shelf_id": 261, "shelf_number": 3131}
1396	shelf	UPDATE	262	2025-03-29 22:06:31.687391	{"rackid": 53, "shelf_id": 262, "shelf_number": 3600}	{"rackid": 53, "shelf_id": 262, "shelf_number": 3132}
1397	shelf	UPDATE	263	2025-03-29 22:06:31.687391	{"rackid": 53, "shelf_id": 263, "shelf_number": 3700}	{"rackid": 53, "shelf_id": 263, "shelf_number": 3133}
1398	shelf	UPDATE	264	2025-03-29 22:06:31.687391	{"rackid": 53, "shelf_id": 264, "shelf_number": 3800}	{"rackid": 53, "shelf_id": 264, "shelf_number": 3134}
1399	shelf	UPDATE	265	2025-03-29 22:06:31.687391	{"rackid": 53, "shelf_id": 265, "shelf_number": 3900}	{"rackid": 53, "shelf_id": 265, "shelf_number": 3135}
1400	shelf	UPDATE	266	2025-03-29 22:06:31.687391	{"rackid": 54, "shelf_id": 266, "shelf_number": 3600}	{"rackid": 54, "shelf_id": 266, "shelf_number": 3141}
1401	shelf	UPDATE	267	2025-03-29 22:06:31.687391	{"rackid": 54, "shelf_id": 267, "shelf_number": 3700}	{"rackid": 54, "shelf_id": 267, "shelf_number": 3142}
1402	shelf	UPDATE	268	2025-03-29 22:06:31.687391	{"rackid": 54, "shelf_id": 268, "shelf_number": 3800}	{"rackid": 54, "shelf_id": 268, "shelf_number": 3143}
1403	shelf	UPDATE	269	2025-03-29 22:06:31.687391	{"rackid": 54, "shelf_id": 269, "shelf_number": 3900}	{"rackid": 54, "shelf_id": 269, "shelf_number": 3144}
1404	shelf	UPDATE	270	2025-03-29 22:06:31.687391	{"rackid": 54, "shelf_id": 270, "shelf_number": 4000}	{"rackid": 54, "shelf_id": 270, "shelf_number": 3145}
1405	shelf	UPDATE	271	2025-03-29 22:06:31.687391	{"rackid": 55, "shelf_id": 271, "shelf_number": 3700}	{"rackid": 55, "shelf_id": 271, "shelf_number": 3151}
1406	shelf	UPDATE	272	2025-03-29 22:06:31.687391	{"rackid": 55, "shelf_id": 272, "shelf_number": 3800}	{"rackid": 55, "shelf_id": 272, "shelf_number": 3152}
1407	shelf	UPDATE	273	2025-03-29 22:06:31.687391	{"rackid": 55, "shelf_id": 273, "shelf_number": 3900}	{"rackid": 55, "shelf_id": 273, "shelf_number": 3153}
1408	shelf	UPDATE	274	2025-03-29 22:06:31.687391	{"rackid": 55, "shelf_id": 274, "shelf_number": 4000}	{"rackid": 55, "shelf_id": 274, "shelf_number": 3154}
1409	shelf	UPDATE	275	2025-03-29 22:06:31.687391	{"rackid": 55, "shelf_id": 275, "shelf_number": 4100}	{"rackid": 55, "shelf_id": 275, "shelf_number": 3155}
1410	shelf	UPDATE	276	2025-03-29 22:06:31.687391	{"rackid": 56, "shelf_id": 276, "shelf_number": 3400}	{"rackid": 56, "shelf_id": 276, "shelf_number": 3211}
1411	shelf	UPDATE	277	2025-03-29 22:06:31.687391	{"rackid": 56, "shelf_id": 277, "shelf_number": 3500}	{"rackid": 56, "shelf_id": 277, "shelf_number": 3212}
1412	shelf	UPDATE	278	2025-03-29 22:06:31.687391	{"rackid": 56, "shelf_id": 278, "shelf_number": 3600}	{"rackid": 56, "shelf_id": 278, "shelf_number": 3213}
1413	shelf	UPDATE	279	2025-03-29 22:06:31.687391	{"rackid": 56, "shelf_id": 279, "shelf_number": 3700}	{"rackid": 56, "shelf_id": 279, "shelf_number": 3214}
1414	shelf	UPDATE	280	2025-03-29 22:06:31.687391	{"rackid": 56, "shelf_id": 280, "shelf_number": 3800}	{"rackid": 56, "shelf_id": 280, "shelf_number": 3215}
1415	shelf	UPDATE	281	2025-03-29 22:06:31.687391	{"rackid": 57, "shelf_id": 281, "shelf_number": 3500}	{"rackid": 57, "shelf_id": 281, "shelf_number": 3221}
1416	shelf	UPDATE	282	2025-03-29 22:06:31.687391	{"rackid": 57, "shelf_id": 282, "shelf_number": 3600}	{"rackid": 57, "shelf_id": 282, "shelf_number": 3222}
1417	shelf	UPDATE	283	2025-03-29 22:06:31.687391	{"rackid": 57, "shelf_id": 283, "shelf_number": 3700}	{"rackid": 57, "shelf_id": 283, "shelf_number": 3223}
1418	shelf	UPDATE	284	2025-03-29 22:06:31.687391	{"rackid": 57, "shelf_id": 284, "shelf_number": 3800}	{"rackid": 57, "shelf_id": 284, "shelf_number": 3224}
1419	shelf	UPDATE	285	2025-03-29 22:06:31.687391	{"rackid": 57, "shelf_id": 285, "shelf_number": 3900}	{"rackid": 57, "shelf_id": 285, "shelf_number": 3225}
1420	shelf	UPDATE	286	2025-03-29 22:06:31.687391	{"rackid": 58, "shelf_id": 286, "shelf_number": 3600}	{"rackid": 58, "shelf_id": 286, "shelf_number": 3231}
1421	shelf	UPDATE	287	2025-03-29 22:06:31.687391	{"rackid": 58, "shelf_id": 287, "shelf_number": 3700}	{"rackid": 58, "shelf_id": 287, "shelf_number": 3232}
1422	shelf	UPDATE	288	2025-03-29 22:06:31.687391	{"rackid": 58, "shelf_id": 288, "shelf_number": 3800}	{"rackid": 58, "shelf_id": 288, "shelf_number": 3233}
1423	shelf	UPDATE	289	2025-03-29 22:06:31.687391	{"rackid": 58, "shelf_id": 289, "shelf_number": 3900}	{"rackid": 58, "shelf_id": 289, "shelf_number": 3234}
1424	shelf	UPDATE	290	2025-03-29 22:06:31.687391	{"rackid": 58, "shelf_id": 290, "shelf_number": 4000}	{"rackid": 58, "shelf_id": 290, "shelf_number": 3235}
1425	shelf	UPDATE	291	2025-03-29 22:06:31.687391	{"rackid": 59, "shelf_id": 291, "shelf_number": 3700}	{"rackid": 59, "shelf_id": 291, "shelf_number": 3241}
1426	shelf	UPDATE	292	2025-03-29 22:06:31.687391	{"rackid": 59, "shelf_id": 292, "shelf_number": 3800}	{"rackid": 59, "shelf_id": 292, "shelf_number": 3242}
1427	shelf	UPDATE	293	2025-03-29 22:06:31.687391	{"rackid": 59, "shelf_id": 293, "shelf_number": 3900}	{"rackid": 59, "shelf_id": 293, "shelf_number": 3243}
1428	shelf	UPDATE	294	2025-03-29 22:06:31.687391	{"rackid": 59, "shelf_id": 294, "shelf_number": 4000}	{"rackid": 59, "shelf_id": 294, "shelf_number": 3244}
1429	shelf	UPDATE	295	2025-03-29 22:06:31.687391	{"rackid": 59, "shelf_id": 295, "shelf_number": 4100}	{"rackid": 59, "shelf_id": 295, "shelf_number": 3245}
1430	shelf	UPDATE	296	2025-03-29 22:06:31.687391	{"rackid": 60, "shelf_id": 296, "shelf_number": 3800}	{"rackid": 60, "shelf_id": 296, "shelf_number": 3251}
1431	shelf	UPDATE	297	2025-03-29 22:06:31.687391	{"rackid": 60, "shelf_id": 297, "shelf_number": 3900}	{"rackid": 60, "shelf_id": 297, "shelf_number": 3252}
1432	shelf	UPDATE	298	2025-03-29 22:06:31.687391	{"rackid": 60, "shelf_id": 298, "shelf_number": 4000}	{"rackid": 60, "shelf_id": 298, "shelf_number": 3253}
1433	shelf	UPDATE	299	2025-03-29 22:06:31.687391	{"rackid": 60, "shelf_id": 299, "shelf_number": 4100}	{"rackid": 60, "shelf_id": 299, "shelf_number": 3254}
1434	shelf	UPDATE	300	2025-03-29 22:06:31.687391	{"rackid": 60, "shelf_id": 300, "shelf_number": 4200}	{"rackid": 60, "shelf_id": 300, "shelf_number": 3255}
1435	shelf	UPDATE	301	2025-03-29 22:06:31.687391	{"rackid": 61, "shelf_id": 301, "shelf_number": 3500}	{"rackid": 61, "shelf_id": 301, "shelf_number": 3311}
1436	shelf	UPDATE	302	2025-03-29 22:06:31.687391	{"rackid": 61, "shelf_id": 302, "shelf_number": 3600}	{"rackid": 61, "shelf_id": 302, "shelf_number": 3312}
1437	shelf	UPDATE	303	2025-03-29 22:06:31.687391	{"rackid": 61, "shelf_id": 303, "shelf_number": 3700}	{"rackid": 61, "shelf_id": 303, "shelf_number": 3313}
1438	shelf	UPDATE	304	2025-03-29 22:06:31.687391	{"rackid": 61, "shelf_id": 304, "shelf_number": 3800}	{"rackid": 61, "shelf_id": 304, "shelf_number": 3314}
1439	shelf	UPDATE	305	2025-03-29 22:06:31.687391	{"rackid": 61, "shelf_id": 305, "shelf_number": 3900}	{"rackid": 61, "shelf_id": 305, "shelf_number": 3315}
1440	shelf	UPDATE	306	2025-03-29 22:06:31.687391	{"rackid": 62, "shelf_id": 306, "shelf_number": 3600}	{"rackid": 62, "shelf_id": 306, "shelf_number": 3321}
1441	shelf	UPDATE	307	2025-03-29 22:06:31.687391	{"rackid": 62, "shelf_id": 307, "shelf_number": 3700}	{"rackid": 62, "shelf_id": 307, "shelf_number": 3322}
1442	shelf	UPDATE	308	2025-03-29 22:06:31.687391	{"rackid": 62, "shelf_id": 308, "shelf_number": 3800}	{"rackid": 62, "shelf_id": 308, "shelf_number": 3323}
1443	shelf	UPDATE	309	2025-03-29 22:06:31.687391	{"rackid": 62, "shelf_id": 309, "shelf_number": 3900}	{"rackid": 62, "shelf_id": 309, "shelf_number": 3324}
1444	shelf	UPDATE	310	2025-03-29 22:06:31.687391	{"rackid": 62, "shelf_id": 310, "shelf_number": 4000}	{"rackid": 62, "shelf_id": 310, "shelf_number": 3325}
1445	shelf	UPDATE	311	2025-03-29 22:06:31.687391	{"rackid": 63, "shelf_id": 311, "shelf_number": 3700}	{"rackid": 63, "shelf_id": 311, "shelf_number": 3331}
1446	shelf	UPDATE	312	2025-03-29 22:06:31.687391	{"rackid": 63, "shelf_id": 312, "shelf_number": 3800}	{"rackid": 63, "shelf_id": 312, "shelf_number": 3332}
1447	shelf	UPDATE	313	2025-03-29 22:06:31.687391	{"rackid": 63, "shelf_id": 313, "shelf_number": 3900}	{"rackid": 63, "shelf_id": 313, "shelf_number": 3333}
1448	shelf	UPDATE	314	2025-03-29 22:06:31.687391	{"rackid": 63, "shelf_id": 314, "shelf_number": 4000}	{"rackid": 63, "shelf_id": 314, "shelf_number": 3334}
1449	shelf	UPDATE	315	2025-03-29 22:06:31.687391	{"rackid": 63, "shelf_id": 315, "shelf_number": 4100}	{"rackid": 63, "shelf_id": 315, "shelf_number": 3335}
1450	shelf	UPDATE	316	2025-03-29 22:06:31.687391	{"rackid": 64, "shelf_id": 316, "shelf_number": 3800}	{"rackid": 64, "shelf_id": 316, "shelf_number": 3341}
1451	shelf	UPDATE	317	2025-03-29 22:06:31.687391	{"rackid": 64, "shelf_id": 317, "shelf_number": 3900}	{"rackid": 64, "shelf_id": 317, "shelf_number": 3342}
1452	shelf	UPDATE	318	2025-03-29 22:06:31.687391	{"rackid": 64, "shelf_id": 318, "shelf_number": 4000}	{"rackid": 64, "shelf_id": 318, "shelf_number": 3343}
1453	shelf	UPDATE	319	2025-03-29 22:06:31.687391	{"rackid": 64, "shelf_id": 319, "shelf_number": 4100}	{"rackid": 64, "shelf_id": 319, "shelf_number": 3344}
1454	shelf	UPDATE	320	2025-03-29 22:06:31.687391	{"rackid": 64, "shelf_id": 320, "shelf_number": 4200}	{"rackid": 64, "shelf_id": 320, "shelf_number": 3345}
1455	shelf	UPDATE	321	2025-03-29 22:06:31.687391	{"rackid": 65, "shelf_id": 321, "shelf_number": 3900}	{"rackid": 65, "shelf_id": 321, "shelf_number": 3351}
1456	shelf	UPDATE	322	2025-03-29 22:06:31.687391	{"rackid": 65, "shelf_id": 322, "shelf_number": 4000}	{"rackid": 65, "shelf_id": 322, "shelf_number": 3352}
1457	shelf	UPDATE	323	2025-03-29 22:06:31.687391	{"rackid": 65, "shelf_id": 323, "shelf_number": 4100}	{"rackid": 65, "shelf_id": 323, "shelf_number": 3353}
1458	shelf	UPDATE	324	2025-03-29 22:06:31.687391	{"rackid": 65, "shelf_id": 324, "shelf_number": 4200}	{"rackid": 65, "shelf_id": 324, "shelf_number": 3354}
1459	shelf	UPDATE	325	2025-03-29 22:06:31.687391	{"rackid": 65, "shelf_id": 325, "shelf_number": 4300}	{"rackid": 65, "shelf_id": 325, "shelf_number": 3355}
1460	shelf	UPDATE	326	2025-03-29 22:06:31.687391	{"rackid": 66, "shelf_id": 326, "shelf_number": 3600}	{"rackid": 66, "shelf_id": 326, "shelf_number": 3411}
1461	shelf	UPDATE	327	2025-03-29 22:06:31.687391	{"rackid": 66, "shelf_id": 327, "shelf_number": 3700}	{"rackid": 66, "shelf_id": 327, "shelf_number": 3412}
1462	shelf	UPDATE	328	2025-03-29 22:06:31.687391	{"rackid": 66, "shelf_id": 328, "shelf_number": 3800}	{"rackid": 66, "shelf_id": 328, "shelf_number": 3413}
1463	shelf	UPDATE	329	2025-03-29 22:06:31.687391	{"rackid": 66, "shelf_id": 329, "shelf_number": 3900}	{"rackid": 66, "shelf_id": 329, "shelf_number": 3414}
1464	shelf	UPDATE	330	2025-03-29 22:06:31.687391	{"rackid": 66, "shelf_id": 330, "shelf_number": 4000}	{"rackid": 66, "shelf_id": 330, "shelf_number": 3415}
1465	shelf	UPDATE	331	2025-03-29 22:06:31.687391	{"rackid": 67, "shelf_id": 331, "shelf_number": 3700}	{"rackid": 67, "shelf_id": 331, "shelf_number": 3421}
1466	shelf	UPDATE	332	2025-03-29 22:06:31.687391	{"rackid": 67, "shelf_id": 332, "shelf_number": 3800}	{"rackid": 67, "shelf_id": 332, "shelf_number": 3422}
1467	shelf	UPDATE	333	2025-03-29 22:06:31.687391	{"rackid": 67, "shelf_id": 333, "shelf_number": 3900}	{"rackid": 67, "shelf_id": 333, "shelf_number": 3423}
1468	shelf	UPDATE	334	2025-03-29 22:06:31.687391	{"rackid": 67, "shelf_id": 334, "shelf_number": 4000}	{"rackid": 67, "shelf_id": 334, "shelf_number": 3424}
1469	shelf	UPDATE	335	2025-03-29 22:06:31.687391	{"rackid": 67, "shelf_id": 335, "shelf_number": 4100}	{"rackid": 67, "shelf_id": 335, "shelf_number": 3425}
1470	shelf	UPDATE	336	2025-03-29 22:06:31.687391	{"rackid": 68, "shelf_id": 336, "shelf_number": 3800}	{"rackid": 68, "shelf_id": 336, "shelf_number": 3431}
1471	shelf	UPDATE	337	2025-03-29 22:06:31.687391	{"rackid": 68, "shelf_id": 337, "shelf_number": 3900}	{"rackid": 68, "shelf_id": 337, "shelf_number": 3432}
1472	shelf	UPDATE	338	2025-03-29 22:06:31.687391	{"rackid": 68, "shelf_id": 338, "shelf_number": 4000}	{"rackid": 68, "shelf_id": 338, "shelf_number": 3433}
1473	shelf	UPDATE	339	2025-03-29 22:06:31.687391	{"rackid": 68, "shelf_id": 339, "shelf_number": 4100}	{"rackid": 68, "shelf_id": 339, "shelf_number": 3434}
1474	shelf	UPDATE	340	2025-03-29 22:06:31.687391	{"rackid": 68, "shelf_id": 340, "shelf_number": 4200}	{"rackid": 68, "shelf_id": 340, "shelf_number": 3435}
1475	shelf	UPDATE	341	2025-03-29 22:06:31.687391	{"rackid": 69, "shelf_id": 341, "shelf_number": 3900}	{"rackid": 69, "shelf_id": 341, "shelf_number": 3441}
1476	shelf	UPDATE	342	2025-03-29 22:06:31.687391	{"rackid": 69, "shelf_id": 342, "shelf_number": 4000}	{"rackid": 69, "shelf_id": 342, "shelf_number": 3442}
1477	shelf	UPDATE	343	2025-03-29 22:06:31.687391	{"rackid": 69, "shelf_id": 343, "shelf_number": 4100}	{"rackid": 69, "shelf_id": 343, "shelf_number": 3443}
1478	shelf	UPDATE	344	2025-03-29 22:06:31.687391	{"rackid": 69, "shelf_id": 344, "shelf_number": 4200}	{"rackid": 69, "shelf_id": 344, "shelf_number": 3444}
1479	shelf	UPDATE	345	2025-03-29 22:06:31.687391	{"rackid": 69, "shelf_id": 345, "shelf_number": 4300}	{"rackid": 69, "shelf_id": 345, "shelf_number": 3445}
1480	shelf	UPDATE	346	2025-03-29 22:06:31.687391	{"rackid": 70, "shelf_id": 346, "shelf_number": 4000}	{"rackid": 70, "shelf_id": 346, "shelf_number": 3451}
1481	shelf	UPDATE	347	2025-03-29 22:06:31.687391	{"rackid": 70, "shelf_id": 347, "shelf_number": 4100}	{"rackid": 70, "shelf_id": 347, "shelf_number": 3452}
1482	shelf	UPDATE	348	2025-03-29 22:06:31.687391	{"rackid": 70, "shelf_id": 348, "shelf_number": 4200}	{"rackid": 70, "shelf_id": 348, "shelf_number": 3453}
1483	shelf	UPDATE	349	2025-03-29 22:06:31.687391	{"rackid": 70, "shelf_id": 349, "shelf_number": 4300}	{"rackid": 70, "shelf_id": 349, "shelf_number": 3454}
1484	shelf	UPDATE	350	2025-03-29 22:06:31.687391	{"rackid": 70, "shelf_id": 350, "shelf_number": 4400}	{"rackid": 70, "shelf_id": 350, "shelf_number": 3455}
1485	shelf	UPDATE	351	2025-03-29 22:06:31.687391	{"rackid": 71, "shelf_id": 351, "shelf_number": 3700}	{"rackid": 71, "shelf_id": 351, "shelf_number": 3511}
1486	shelf	UPDATE	352	2025-03-29 22:06:31.687391	{"rackid": 71, "shelf_id": 352, "shelf_number": 3800}	{"rackid": 71, "shelf_id": 352, "shelf_number": 3512}
1487	shelf	UPDATE	353	2025-03-29 22:06:31.687391	{"rackid": 71, "shelf_id": 353, "shelf_number": 3900}	{"rackid": 71, "shelf_id": 353, "shelf_number": 3513}
1488	shelf	UPDATE	354	2025-03-29 22:06:31.687391	{"rackid": 71, "shelf_id": 354, "shelf_number": 4000}	{"rackid": 71, "shelf_id": 354, "shelf_number": 3514}
1489	shelf	UPDATE	355	2025-03-29 22:06:31.687391	{"rackid": 71, "shelf_id": 355, "shelf_number": 4100}	{"rackid": 71, "shelf_id": 355, "shelf_number": 3515}
1490	shelf	UPDATE	356	2025-03-29 22:06:31.687391	{"rackid": 72, "shelf_id": 356, "shelf_number": 3800}	{"rackid": 72, "shelf_id": 356, "shelf_number": 3521}
1491	shelf	UPDATE	357	2025-03-29 22:06:31.687391	{"rackid": 72, "shelf_id": 357, "shelf_number": 3900}	{"rackid": 72, "shelf_id": 357, "shelf_number": 3522}
1492	shelf	UPDATE	358	2025-03-29 22:06:31.687391	{"rackid": 72, "shelf_id": 358, "shelf_number": 4000}	{"rackid": 72, "shelf_id": 358, "shelf_number": 3523}
1493	shelf	UPDATE	359	2025-03-29 22:06:31.687391	{"rackid": 72, "shelf_id": 359, "shelf_number": 4100}	{"rackid": 72, "shelf_id": 359, "shelf_number": 3524}
1494	shelf	UPDATE	360	2025-03-29 22:06:31.687391	{"rackid": 72, "shelf_id": 360, "shelf_number": 4200}	{"rackid": 72, "shelf_id": 360, "shelf_number": 3525}
1495	shelf	UPDATE	361	2025-03-29 22:06:31.687391	{"rackid": 73, "shelf_id": 361, "shelf_number": 3900}	{"rackid": 73, "shelf_id": 361, "shelf_number": 3531}
1496	shelf	UPDATE	362	2025-03-29 22:06:31.687391	{"rackid": 73, "shelf_id": 362, "shelf_number": 4000}	{"rackid": 73, "shelf_id": 362, "shelf_number": 3532}
1497	shelf	UPDATE	363	2025-03-29 22:06:31.687391	{"rackid": 73, "shelf_id": 363, "shelf_number": 4100}	{"rackid": 73, "shelf_id": 363, "shelf_number": 3533}
1498	shelf	UPDATE	364	2025-03-29 22:06:31.687391	{"rackid": 73, "shelf_id": 364, "shelf_number": 4200}	{"rackid": 73, "shelf_id": 364, "shelf_number": 3534}
1499	shelf	UPDATE	365	2025-03-29 22:06:31.687391	{"rackid": 73, "shelf_id": 365, "shelf_number": 4300}	{"rackid": 73, "shelf_id": 365, "shelf_number": 3535}
1500	shelf	UPDATE	366	2025-03-29 22:06:31.687391	{"rackid": 74, "shelf_id": 366, "shelf_number": 4000}	{"rackid": 74, "shelf_id": 366, "shelf_number": 3541}
1501	shelf	UPDATE	367	2025-03-29 22:06:31.687391	{"rackid": 74, "shelf_id": 367, "shelf_number": 4100}	{"rackid": 74, "shelf_id": 367, "shelf_number": 3542}
1502	shelf	UPDATE	368	2025-03-29 22:06:31.687391	{"rackid": 74, "shelf_id": 368, "shelf_number": 4200}	{"rackid": 74, "shelf_id": 368, "shelf_number": 3543}
1503	shelf	UPDATE	369	2025-03-29 22:06:31.687391	{"rackid": 74, "shelf_id": 369, "shelf_number": 4300}	{"rackid": 74, "shelf_id": 369, "shelf_number": 3544}
1504	shelf	UPDATE	370	2025-03-29 22:06:31.687391	{"rackid": 74, "shelf_id": 370, "shelf_number": 4400}	{"rackid": 74, "shelf_id": 370, "shelf_number": 3545}
1505	shelf	UPDATE	371	2025-03-29 22:06:31.687391	{"rackid": 75, "shelf_id": 371, "shelf_number": 4100}	{"rackid": 75, "shelf_id": 371, "shelf_number": 3551}
1506	shelf	UPDATE	372	2025-03-29 22:06:31.687391	{"rackid": 75, "shelf_id": 372, "shelf_number": 4200}	{"rackid": 75, "shelf_id": 372, "shelf_number": 3552}
1507	shelf	UPDATE	373	2025-03-29 22:06:31.687391	{"rackid": 75, "shelf_id": 373, "shelf_number": 4300}	{"rackid": 75, "shelf_id": 373, "shelf_number": 3553}
1508	shelf	UPDATE	374	2025-03-29 22:06:31.687391	{"rackid": 75, "shelf_id": 374, "shelf_number": 4400}	{"rackid": 75, "shelf_id": 374, "shelf_number": 3554}
1509	shelf	UPDATE	375	2025-03-29 22:06:31.687391	{"rackid": 75, "shelf_id": 375, "shelf_number": 4500}	{"rackid": 75, "shelf_id": 375, "shelf_number": 3555}
1510	shelf	UPDATE	376	2025-03-29 22:06:31.687391	{"rackid": 76, "shelf_id": 376, "shelf_number": 4300}	{"rackid": 76, "shelf_id": 376, "shelf_number": 4111}
1511	shelf	UPDATE	377	2025-03-29 22:06:31.687391	{"rackid": 76, "shelf_id": 377, "shelf_number": 4400}	{"rackid": 76, "shelf_id": 377, "shelf_number": 4112}
1512	shelf	UPDATE	378	2025-03-29 22:06:31.687391	{"rackid": 76, "shelf_id": 378, "shelf_number": 4500}	{"rackid": 76, "shelf_id": 378, "shelf_number": 4113}
1513	shelf	UPDATE	379	2025-03-29 22:06:31.687391	{"rackid": 76, "shelf_id": 379, "shelf_number": 4600}	{"rackid": 76, "shelf_id": 379, "shelf_number": 4114}
1514	shelf	UPDATE	380	2025-03-29 22:06:31.687391	{"rackid": 76, "shelf_id": 380, "shelf_number": 4700}	{"rackid": 76, "shelf_id": 380, "shelf_number": 4115}
1515	shelf	UPDATE	381	2025-03-29 22:06:31.687391	{"rackid": 77, "shelf_id": 381, "shelf_number": 4400}	{"rackid": 77, "shelf_id": 381, "shelf_number": 4121}
1516	shelf	UPDATE	382	2025-03-29 22:06:31.687391	{"rackid": 77, "shelf_id": 382, "shelf_number": 4500}	{"rackid": 77, "shelf_id": 382, "shelf_number": 4122}
1517	shelf	UPDATE	383	2025-03-29 22:06:31.687391	{"rackid": 77, "shelf_id": 383, "shelf_number": 4600}	{"rackid": 77, "shelf_id": 383, "shelf_number": 4123}
1518	shelf	UPDATE	384	2025-03-29 22:06:31.687391	{"rackid": 77, "shelf_id": 384, "shelf_number": 4700}	{"rackid": 77, "shelf_id": 384, "shelf_number": 4124}
1519	shelf	UPDATE	385	2025-03-29 22:06:31.687391	{"rackid": 77, "shelf_id": 385, "shelf_number": 4800}	{"rackid": 77, "shelf_id": 385, "shelf_number": 4125}
1520	shelf	UPDATE	386	2025-03-29 22:06:31.687391	{"rackid": 78, "shelf_id": 386, "shelf_number": 4500}	{"rackid": 78, "shelf_id": 386, "shelf_number": 4131}
1521	shelf	UPDATE	387	2025-03-29 22:06:31.687391	{"rackid": 78, "shelf_id": 387, "shelf_number": 4600}	{"rackid": 78, "shelf_id": 387, "shelf_number": 4132}
1522	shelf	UPDATE	388	2025-03-29 22:06:31.687391	{"rackid": 78, "shelf_id": 388, "shelf_number": 4700}	{"rackid": 78, "shelf_id": 388, "shelf_number": 4133}
1523	shelf	UPDATE	389	2025-03-29 22:06:31.687391	{"rackid": 78, "shelf_id": 389, "shelf_number": 4800}	{"rackid": 78, "shelf_id": 389, "shelf_number": 4134}
1524	shelf	UPDATE	390	2025-03-29 22:06:31.687391	{"rackid": 78, "shelf_id": 390, "shelf_number": 4900}	{"rackid": 78, "shelf_id": 390, "shelf_number": 4135}
1525	shelf	UPDATE	391	2025-03-29 22:06:31.687391	{"rackid": 79, "shelf_id": 391, "shelf_number": 4600}	{"rackid": 79, "shelf_id": 391, "shelf_number": 4141}
1526	shelf	UPDATE	392	2025-03-29 22:06:31.687391	{"rackid": 79, "shelf_id": 392, "shelf_number": 4700}	{"rackid": 79, "shelf_id": 392, "shelf_number": 4142}
1527	shelf	UPDATE	393	2025-03-29 22:06:31.687391	{"rackid": 79, "shelf_id": 393, "shelf_number": 4800}	{"rackid": 79, "shelf_id": 393, "shelf_number": 4143}
1528	shelf	UPDATE	394	2025-03-29 22:06:31.687391	{"rackid": 79, "shelf_id": 394, "shelf_number": 4900}	{"rackid": 79, "shelf_id": 394, "shelf_number": 4144}
1529	shelf	UPDATE	395	2025-03-29 22:06:31.687391	{"rackid": 79, "shelf_id": 395, "shelf_number": 5000}	{"rackid": 79, "shelf_id": 395, "shelf_number": 4145}
1530	shelf	UPDATE	396	2025-03-29 22:06:31.687391	{"rackid": 80, "shelf_id": 396, "shelf_number": 4700}	{"rackid": 80, "shelf_id": 396, "shelf_number": 4151}
1531	shelf	UPDATE	397	2025-03-29 22:06:31.687391	{"rackid": 80, "shelf_id": 397, "shelf_number": 4800}	{"rackid": 80, "shelf_id": 397, "shelf_number": 4152}
1532	shelf	UPDATE	398	2025-03-29 22:06:31.687391	{"rackid": 80, "shelf_id": 398, "shelf_number": 4900}	{"rackid": 80, "shelf_id": 398, "shelf_number": 4153}
1533	shelf	UPDATE	399	2025-03-29 22:06:31.687391	{"rackid": 80, "shelf_id": 399, "shelf_number": 5000}	{"rackid": 80, "shelf_id": 399, "shelf_number": 4154}
1534	shelf	UPDATE	400	2025-03-29 22:06:31.687391	{"rackid": 80, "shelf_id": 400, "shelf_number": 5100}	{"rackid": 80, "shelf_id": 400, "shelf_number": 4155}
1535	shelf	UPDATE	401	2025-03-29 22:06:31.687391	{"rackid": 81, "shelf_id": 401, "shelf_number": 4400}	{"rackid": 81, "shelf_id": 401, "shelf_number": 4211}
1536	shelf	UPDATE	402	2025-03-29 22:06:31.687391	{"rackid": 81, "shelf_id": 402, "shelf_number": 4500}	{"rackid": 81, "shelf_id": 402, "shelf_number": 4212}
1537	shelf	UPDATE	403	2025-03-29 22:06:31.687391	{"rackid": 81, "shelf_id": 403, "shelf_number": 4600}	{"rackid": 81, "shelf_id": 403, "shelf_number": 4213}
1538	shelf	UPDATE	404	2025-03-29 22:06:31.687391	{"rackid": 81, "shelf_id": 404, "shelf_number": 4700}	{"rackid": 81, "shelf_id": 404, "shelf_number": 4214}
1539	shelf	UPDATE	405	2025-03-29 22:06:31.687391	{"rackid": 81, "shelf_id": 405, "shelf_number": 4800}	{"rackid": 81, "shelf_id": 405, "shelf_number": 4215}
1540	shelf	UPDATE	406	2025-03-29 22:06:31.687391	{"rackid": 82, "shelf_id": 406, "shelf_number": 4500}	{"rackid": 82, "shelf_id": 406, "shelf_number": 4221}
1541	shelf	UPDATE	407	2025-03-29 22:06:31.687391	{"rackid": 82, "shelf_id": 407, "shelf_number": 4600}	{"rackid": 82, "shelf_id": 407, "shelf_number": 4222}
1542	shelf	UPDATE	408	2025-03-29 22:06:31.687391	{"rackid": 82, "shelf_id": 408, "shelf_number": 4700}	{"rackid": 82, "shelf_id": 408, "shelf_number": 4223}
1543	shelf	UPDATE	409	2025-03-29 22:06:31.687391	{"rackid": 82, "shelf_id": 409, "shelf_number": 4800}	{"rackid": 82, "shelf_id": 409, "shelf_number": 4224}
1544	shelf	UPDATE	410	2025-03-29 22:06:31.687391	{"rackid": 82, "shelf_id": 410, "shelf_number": 4900}	{"rackid": 82, "shelf_id": 410, "shelf_number": 4225}
1545	shelf	UPDATE	411	2025-03-29 22:06:31.687391	{"rackid": 83, "shelf_id": 411, "shelf_number": 4600}	{"rackid": 83, "shelf_id": 411, "shelf_number": 4231}
1546	shelf	UPDATE	412	2025-03-29 22:06:31.687391	{"rackid": 83, "shelf_id": 412, "shelf_number": 4700}	{"rackid": 83, "shelf_id": 412, "shelf_number": 4232}
1547	shelf	UPDATE	413	2025-03-29 22:06:31.687391	{"rackid": 83, "shelf_id": 413, "shelf_number": 4800}	{"rackid": 83, "shelf_id": 413, "shelf_number": 4233}
1548	shelf	UPDATE	414	2025-03-29 22:06:31.687391	{"rackid": 83, "shelf_id": 414, "shelf_number": 4900}	{"rackid": 83, "shelf_id": 414, "shelf_number": 4234}
1549	shelf	UPDATE	415	2025-03-29 22:06:31.687391	{"rackid": 83, "shelf_id": 415, "shelf_number": 5000}	{"rackid": 83, "shelf_id": 415, "shelf_number": 4235}
1550	shelf	UPDATE	416	2025-03-29 22:06:31.687391	{"rackid": 84, "shelf_id": 416, "shelf_number": 4700}	{"rackid": 84, "shelf_id": 416, "shelf_number": 4241}
1551	shelf	UPDATE	417	2025-03-29 22:06:31.687391	{"rackid": 84, "shelf_id": 417, "shelf_number": 4800}	{"rackid": 84, "shelf_id": 417, "shelf_number": 4242}
1552	shelf	UPDATE	418	2025-03-29 22:06:31.687391	{"rackid": 84, "shelf_id": 418, "shelf_number": 4900}	{"rackid": 84, "shelf_id": 418, "shelf_number": 4243}
1553	shelf	UPDATE	419	2025-03-29 22:06:31.687391	{"rackid": 84, "shelf_id": 419, "shelf_number": 5000}	{"rackid": 84, "shelf_id": 419, "shelf_number": 4244}
1554	shelf	UPDATE	420	2025-03-29 22:06:31.687391	{"rackid": 84, "shelf_id": 420, "shelf_number": 5100}	{"rackid": 84, "shelf_id": 420, "shelf_number": 4245}
1555	shelf	UPDATE	421	2025-03-29 22:06:31.687391	{"rackid": 85, "shelf_id": 421, "shelf_number": 4800}	{"rackid": 85, "shelf_id": 421, "shelf_number": 4251}
1556	shelf	UPDATE	422	2025-03-29 22:06:31.687391	{"rackid": 85, "shelf_id": 422, "shelf_number": 4900}	{"rackid": 85, "shelf_id": 422, "shelf_number": 4252}
1557	shelf	UPDATE	423	2025-03-29 22:06:31.687391	{"rackid": 85, "shelf_id": 423, "shelf_number": 5000}	{"rackid": 85, "shelf_id": 423, "shelf_number": 4253}
1558	shelf	UPDATE	424	2025-03-29 22:06:31.687391	{"rackid": 85, "shelf_id": 424, "shelf_number": 5100}	{"rackid": 85, "shelf_id": 424, "shelf_number": 4254}
1559	shelf	UPDATE	425	2025-03-29 22:06:31.687391	{"rackid": 85, "shelf_id": 425, "shelf_number": 5200}	{"rackid": 85, "shelf_id": 425, "shelf_number": 4255}
1560	shelf	UPDATE	426	2025-03-29 22:06:31.687391	{"rackid": 86, "shelf_id": 426, "shelf_number": 4500}	{"rackid": 86, "shelf_id": 426, "shelf_number": 4311}
1561	shelf	UPDATE	427	2025-03-29 22:06:31.687391	{"rackid": 86, "shelf_id": 427, "shelf_number": 4600}	{"rackid": 86, "shelf_id": 427, "shelf_number": 4312}
1562	shelf	UPDATE	428	2025-03-29 22:06:31.687391	{"rackid": 86, "shelf_id": 428, "shelf_number": 4700}	{"rackid": 86, "shelf_id": 428, "shelf_number": 4313}
1563	shelf	UPDATE	429	2025-03-29 22:06:31.687391	{"rackid": 86, "shelf_id": 429, "shelf_number": 4800}	{"rackid": 86, "shelf_id": 429, "shelf_number": 4314}
1564	shelf	UPDATE	430	2025-03-29 22:06:31.687391	{"rackid": 86, "shelf_id": 430, "shelf_number": 4900}	{"rackid": 86, "shelf_id": 430, "shelf_number": 4315}
1565	shelf	UPDATE	431	2025-03-29 22:06:31.687391	{"rackid": 87, "shelf_id": 431, "shelf_number": 4600}	{"rackid": 87, "shelf_id": 431, "shelf_number": 4321}
1566	shelf	UPDATE	432	2025-03-29 22:06:31.687391	{"rackid": 87, "shelf_id": 432, "shelf_number": 4700}	{"rackid": 87, "shelf_id": 432, "shelf_number": 4322}
1567	shelf	UPDATE	433	2025-03-29 22:06:31.687391	{"rackid": 87, "shelf_id": 433, "shelf_number": 4800}	{"rackid": 87, "shelf_id": 433, "shelf_number": 4323}
1568	shelf	UPDATE	434	2025-03-29 22:06:31.687391	{"rackid": 87, "shelf_id": 434, "shelf_number": 4900}	{"rackid": 87, "shelf_id": 434, "shelf_number": 4324}
1569	shelf	UPDATE	435	2025-03-29 22:06:31.687391	{"rackid": 87, "shelf_id": 435, "shelf_number": 5000}	{"rackid": 87, "shelf_id": 435, "shelf_number": 4325}
1570	shelf	UPDATE	436	2025-03-29 22:06:31.687391	{"rackid": 88, "shelf_id": 436, "shelf_number": 4700}	{"rackid": 88, "shelf_id": 436, "shelf_number": 4331}
1571	shelf	UPDATE	437	2025-03-29 22:06:31.687391	{"rackid": 88, "shelf_id": 437, "shelf_number": 4800}	{"rackid": 88, "shelf_id": 437, "shelf_number": 4332}
1572	shelf	UPDATE	438	2025-03-29 22:06:31.687391	{"rackid": 88, "shelf_id": 438, "shelf_number": 4900}	{"rackid": 88, "shelf_id": 438, "shelf_number": 4333}
1573	shelf	UPDATE	439	2025-03-29 22:06:31.687391	{"rackid": 88, "shelf_id": 439, "shelf_number": 5000}	{"rackid": 88, "shelf_id": 439, "shelf_number": 4334}
1574	shelf	UPDATE	440	2025-03-29 22:06:31.687391	{"rackid": 88, "shelf_id": 440, "shelf_number": 5100}	{"rackid": 88, "shelf_id": 440, "shelf_number": 4335}
1575	shelf	UPDATE	441	2025-03-29 22:06:31.687391	{"rackid": 89, "shelf_id": 441, "shelf_number": 4800}	{"rackid": 89, "shelf_id": 441, "shelf_number": 4341}
1576	shelf	UPDATE	442	2025-03-29 22:06:31.687391	{"rackid": 89, "shelf_id": 442, "shelf_number": 4900}	{"rackid": 89, "shelf_id": 442, "shelf_number": 4342}
1577	shelf	UPDATE	443	2025-03-29 22:06:31.687391	{"rackid": 89, "shelf_id": 443, "shelf_number": 5000}	{"rackid": 89, "shelf_id": 443, "shelf_number": 4343}
1578	shelf	UPDATE	444	2025-03-29 22:06:31.687391	{"rackid": 89, "shelf_id": 444, "shelf_number": 5100}	{"rackid": 89, "shelf_id": 444, "shelf_number": 4344}
1579	shelf	UPDATE	445	2025-03-29 22:06:31.687391	{"rackid": 89, "shelf_id": 445, "shelf_number": 5200}	{"rackid": 89, "shelf_id": 445, "shelf_number": 4345}
1580	shelf	UPDATE	446	2025-03-29 22:06:31.687391	{"rackid": 90, "shelf_id": 446, "shelf_number": 4900}	{"rackid": 90, "shelf_id": 446, "shelf_number": 4351}
1581	shelf	UPDATE	447	2025-03-29 22:06:31.687391	{"rackid": 90, "shelf_id": 447, "shelf_number": 5000}	{"rackid": 90, "shelf_id": 447, "shelf_number": 4352}
1582	shelf	UPDATE	448	2025-03-29 22:06:31.687391	{"rackid": 90, "shelf_id": 448, "shelf_number": 5100}	{"rackid": 90, "shelf_id": 448, "shelf_number": 4353}
1583	shelf	UPDATE	449	2025-03-29 22:06:31.687391	{"rackid": 90, "shelf_id": 449, "shelf_number": 5200}	{"rackid": 90, "shelf_id": 449, "shelf_number": 4354}
1584	shelf	UPDATE	450	2025-03-29 22:06:31.687391	{"rackid": 90, "shelf_id": 450, "shelf_number": 5300}	{"rackid": 90, "shelf_id": 450, "shelf_number": 4355}
1585	shelf	UPDATE	451	2025-03-29 22:06:31.687391	{"rackid": 91, "shelf_id": 451, "shelf_number": 4600}	{"rackid": 91, "shelf_id": 451, "shelf_number": 4411}
1586	shelf	UPDATE	452	2025-03-29 22:06:31.687391	{"rackid": 91, "shelf_id": 452, "shelf_number": 4700}	{"rackid": 91, "shelf_id": 452, "shelf_number": 4412}
1587	shelf	UPDATE	453	2025-03-29 22:06:31.687391	{"rackid": 91, "shelf_id": 453, "shelf_number": 4800}	{"rackid": 91, "shelf_id": 453, "shelf_number": 4413}
1588	shelf	UPDATE	454	2025-03-29 22:06:31.687391	{"rackid": 91, "shelf_id": 454, "shelf_number": 4900}	{"rackid": 91, "shelf_id": 454, "shelf_number": 4414}
1589	shelf	UPDATE	455	2025-03-29 22:06:31.687391	{"rackid": 91, "shelf_id": 455, "shelf_number": 5000}	{"rackid": 91, "shelf_id": 455, "shelf_number": 4415}
1590	shelf	UPDATE	456	2025-03-29 22:06:31.687391	{"rackid": 92, "shelf_id": 456, "shelf_number": 4700}	{"rackid": 92, "shelf_id": 456, "shelf_number": 4421}
1591	shelf	UPDATE	457	2025-03-29 22:06:31.687391	{"rackid": 92, "shelf_id": 457, "shelf_number": 4800}	{"rackid": 92, "shelf_id": 457, "shelf_number": 4422}
1592	shelf	UPDATE	458	2025-03-29 22:06:31.687391	{"rackid": 92, "shelf_id": 458, "shelf_number": 4900}	{"rackid": 92, "shelf_id": 458, "shelf_number": 4423}
1593	shelf	UPDATE	459	2025-03-29 22:06:31.687391	{"rackid": 92, "shelf_id": 459, "shelf_number": 5000}	{"rackid": 92, "shelf_id": 459, "shelf_number": 4424}
1594	shelf	UPDATE	460	2025-03-29 22:06:31.687391	{"rackid": 92, "shelf_id": 460, "shelf_number": 5100}	{"rackid": 92, "shelf_id": 460, "shelf_number": 4425}
1595	shelf	UPDATE	461	2025-03-29 22:06:31.687391	{"rackid": 93, "shelf_id": 461, "shelf_number": 4800}	{"rackid": 93, "shelf_id": 461, "shelf_number": 4431}
1596	shelf	UPDATE	462	2025-03-29 22:06:31.687391	{"rackid": 93, "shelf_id": 462, "shelf_number": 4900}	{"rackid": 93, "shelf_id": 462, "shelf_number": 4432}
1597	shelf	UPDATE	463	2025-03-29 22:06:31.687391	{"rackid": 93, "shelf_id": 463, "shelf_number": 5000}	{"rackid": 93, "shelf_id": 463, "shelf_number": 4433}
1598	shelf	UPDATE	464	2025-03-29 22:06:31.687391	{"rackid": 93, "shelf_id": 464, "shelf_number": 5100}	{"rackid": 93, "shelf_id": 464, "shelf_number": 4434}
1599	shelf	UPDATE	465	2025-03-29 22:06:31.687391	{"rackid": 93, "shelf_id": 465, "shelf_number": 5200}	{"rackid": 93, "shelf_id": 465, "shelf_number": 4435}
1600	shelf	UPDATE	466	2025-03-29 22:06:31.687391	{"rackid": 94, "shelf_id": 466, "shelf_number": 4900}	{"rackid": 94, "shelf_id": 466, "shelf_number": 4441}
1601	shelf	UPDATE	467	2025-03-29 22:06:31.687391	{"rackid": 94, "shelf_id": 467, "shelf_number": 5000}	{"rackid": 94, "shelf_id": 467, "shelf_number": 4442}
1602	shelf	UPDATE	468	2025-03-29 22:06:31.687391	{"rackid": 94, "shelf_id": 468, "shelf_number": 5100}	{"rackid": 94, "shelf_id": 468, "shelf_number": 4443}
1603	shelf	UPDATE	469	2025-03-29 22:06:31.687391	{"rackid": 94, "shelf_id": 469, "shelf_number": 5200}	{"rackid": 94, "shelf_id": 469, "shelf_number": 4444}
1604	shelf	UPDATE	470	2025-03-29 22:06:31.687391	{"rackid": 94, "shelf_id": 470, "shelf_number": 5300}	{"rackid": 94, "shelf_id": 470, "shelf_number": 4445}
1605	shelf	UPDATE	471	2025-03-29 22:06:31.687391	{"rackid": 95, "shelf_id": 471, "shelf_number": 5000}	{"rackid": 95, "shelf_id": 471, "shelf_number": 4451}
1606	shelf	UPDATE	472	2025-03-29 22:06:31.687391	{"rackid": 95, "shelf_id": 472, "shelf_number": 5100}	{"rackid": 95, "shelf_id": 472, "shelf_number": 4452}
1607	shelf	UPDATE	473	2025-03-29 22:06:31.687391	{"rackid": 95, "shelf_id": 473, "shelf_number": 5200}	{"rackid": 95, "shelf_id": 473, "shelf_number": 4453}
1608	shelf	UPDATE	474	2025-03-29 22:06:31.687391	{"rackid": 95, "shelf_id": 474, "shelf_number": 5300}	{"rackid": 95, "shelf_id": 474, "shelf_number": 4454}
1609	shelf	UPDATE	475	2025-03-29 22:06:31.687391	{"rackid": 95, "shelf_id": 475, "shelf_number": 5400}	{"rackid": 95, "shelf_id": 475, "shelf_number": 4455}
1610	shelf	UPDATE	476	2025-03-29 22:06:31.687391	{"rackid": 96, "shelf_id": 476, "shelf_number": 4700}	{"rackid": 96, "shelf_id": 476, "shelf_number": 4511}
1611	shelf	UPDATE	477	2025-03-29 22:06:31.687391	{"rackid": 96, "shelf_id": 477, "shelf_number": 4800}	{"rackid": 96, "shelf_id": 477, "shelf_number": 4512}
1612	shelf	UPDATE	478	2025-03-29 22:06:31.687391	{"rackid": 96, "shelf_id": 478, "shelf_number": 4900}	{"rackid": 96, "shelf_id": 478, "shelf_number": 4513}
1613	shelf	UPDATE	479	2025-03-29 22:06:31.687391	{"rackid": 96, "shelf_id": 479, "shelf_number": 5000}	{"rackid": 96, "shelf_id": 479, "shelf_number": 4514}
1614	shelf	UPDATE	480	2025-03-29 22:06:31.687391	{"rackid": 96, "shelf_id": 480, "shelf_number": 5100}	{"rackid": 96, "shelf_id": 480, "shelf_number": 4515}
1615	shelf	UPDATE	481	2025-03-29 22:06:31.687391	{"rackid": 97, "shelf_id": 481, "shelf_number": 4800}	{"rackid": 97, "shelf_id": 481, "shelf_number": 4521}
1616	shelf	UPDATE	482	2025-03-29 22:06:31.687391	{"rackid": 97, "shelf_id": 482, "shelf_number": 4900}	{"rackid": 97, "shelf_id": 482, "shelf_number": 4522}
1617	shelf	UPDATE	483	2025-03-29 22:06:31.687391	{"rackid": 97, "shelf_id": 483, "shelf_number": 5000}	{"rackid": 97, "shelf_id": 483, "shelf_number": 4523}
1618	shelf	UPDATE	484	2025-03-29 22:06:31.687391	{"rackid": 97, "shelf_id": 484, "shelf_number": 5100}	{"rackid": 97, "shelf_id": 484, "shelf_number": 4524}
1619	shelf	UPDATE	485	2025-03-29 22:06:31.687391	{"rackid": 97, "shelf_id": 485, "shelf_number": 5200}	{"rackid": 97, "shelf_id": 485, "shelf_number": 4525}
1620	shelf	UPDATE	486	2025-03-29 22:06:31.687391	{"rackid": 98, "shelf_id": 486, "shelf_number": 4900}	{"rackid": 98, "shelf_id": 486, "shelf_number": 4531}
1621	shelf	UPDATE	487	2025-03-29 22:06:31.687391	{"rackid": 98, "shelf_id": 487, "shelf_number": 5000}	{"rackid": 98, "shelf_id": 487, "shelf_number": 4532}
1622	shelf	UPDATE	488	2025-03-29 22:06:31.687391	{"rackid": 98, "shelf_id": 488, "shelf_number": 5100}	{"rackid": 98, "shelf_id": 488, "shelf_number": 4533}
1623	shelf	UPDATE	489	2025-03-29 22:06:31.687391	{"rackid": 98, "shelf_id": 489, "shelf_number": 5200}	{"rackid": 98, "shelf_id": 489, "shelf_number": 4534}
1624	shelf	UPDATE	490	2025-03-29 22:06:31.687391	{"rackid": 98, "shelf_id": 490, "shelf_number": 5300}	{"rackid": 98, "shelf_id": 490, "shelf_number": 4535}
1625	shelf	UPDATE	491	2025-03-29 22:06:31.687391	{"rackid": 99, "shelf_id": 491, "shelf_number": 5000}	{"rackid": 99, "shelf_id": 491, "shelf_number": 4541}
1626	shelf	UPDATE	492	2025-03-29 22:06:31.687391	{"rackid": 99, "shelf_id": 492, "shelf_number": 5100}	{"rackid": 99, "shelf_id": 492, "shelf_number": 4542}
1627	shelf	UPDATE	493	2025-03-29 22:06:31.687391	{"rackid": 99, "shelf_id": 493, "shelf_number": 5200}	{"rackid": 99, "shelf_id": 493, "shelf_number": 4543}
1628	shelf	UPDATE	494	2025-03-29 22:06:31.687391	{"rackid": 99, "shelf_id": 494, "shelf_number": 5300}	{"rackid": 99, "shelf_id": 494, "shelf_number": 4544}
1629	shelf	UPDATE	495	2025-03-29 22:06:31.687391	{"rackid": 99, "shelf_id": 495, "shelf_number": 5400}	{"rackid": 99, "shelf_id": 495, "shelf_number": 4545}
1630	shelf	UPDATE	496	2025-03-29 22:06:31.687391	{"rackid": 100, "shelf_id": 496, "shelf_number": 5100}	{"rackid": 100, "shelf_id": 496, "shelf_number": 4551}
1631	shelf	UPDATE	497	2025-03-29 22:06:31.687391	{"rackid": 100, "shelf_id": 497, "shelf_number": 5200}	{"rackid": 100, "shelf_id": 497, "shelf_number": 4552}
1632	shelf	UPDATE	498	2025-03-29 22:06:31.687391	{"rackid": 100, "shelf_id": 498, "shelf_number": 5300}	{"rackid": 100, "shelf_id": 498, "shelf_number": 4553}
1633	shelf	UPDATE	499	2025-03-29 22:06:31.687391	{"rackid": 100, "shelf_id": 499, "shelf_number": 5400}	{"rackid": 100, "shelf_id": 499, "shelf_number": 4554}
1634	shelf	UPDATE	500	2025-03-29 22:06:31.687391	{"rackid": 100, "shelf_id": 500, "shelf_number": 5500}	{"rackid": 100, "shelf_id": 500, "shelf_number": 4555}
1635	shelf	UPDATE	501	2025-03-29 22:06:31.687391	{"rackid": 101, "shelf_id": 501, "shelf_number": 5300}	{"rackid": 101, "shelf_id": 501, "shelf_number": 5111}
1636	shelf	UPDATE	502	2025-03-29 22:06:31.687391	{"rackid": 101, "shelf_id": 502, "shelf_number": 5400}	{"rackid": 101, "shelf_id": 502, "shelf_number": 5112}
1637	shelf	UPDATE	503	2025-03-29 22:06:31.687391	{"rackid": 101, "shelf_id": 503, "shelf_number": 5500}	{"rackid": 101, "shelf_id": 503, "shelf_number": 5113}
1638	shelf	UPDATE	504	2025-03-29 22:06:31.687391	{"rackid": 101, "shelf_id": 504, "shelf_number": 5600}	{"rackid": 101, "shelf_id": 504, "shelf_number": 5114}
1639	shelf	UPDATE	505	2025-03-29 22:06:31.687391	{"rackid": 101, "shelf_id": 505, "shelf_number": 5700}	{"rackid": 101, "shelf_id": 505, "shelf_number": 5115}
1640	shelf	UPDATE	506	2025-03-29 22:06:31.687391	{"rackid": 102, "shelf_id": 506, "shelf_number": 5400}	{"rackid": 102, "shelf_id": 506, "shelf_number": 5121}
1641	shelf	UPDATE	507	2025-03-29 22:06:31.687391	{"rackid": 102, "shelf_id": 507, "shelf_number": 5500}	{"rackid": 102, "shelf_id": 507, "shelf_number": 5122}
1642	shelf	UPDATE	508	2025-03-29 22:06:31.687391	{"rackid": 102, "shelf_id": 508, "shelf_number": 5600}	{"rackid": 102, "shelf_id": 508, "shelf_number": 5123}
1643	shelf	UPDATE	509	2025-03-29 22:06:31.687391	{"rackid": 102, "shelf_id": 509, "shelf_number": 5700}	{"rackid": 102, "shelf_id": 509, "shelf_number": 5124}
1644	shelf	UPDATE	510	2025-03-29 22:06:31.687391	{"rackid": 102, "shelf_id": 510, "shelf_number": 5800}	{"rackid": 102, "shelf_id": 510, "shelf_number": 5125}
1645	shelf	UPDATE	511	2025-03-29 22:06:31.687391	{"rackid": 103, "shelf_id": 511, "shelf_number": 5500}	{"rackid": 103, "shelf_id": 511, "shelf_number": 5131}
1646	shelf	UPDATE	512	2025-03-29 22:06:31.687391	{"rackid": 103, "shelf_id": 512, "shelf_number": 5600}	{"rackid": 103, "shelf_id": 512, "shelf_number": 5132}
1647	shelf	UPDATE	513	2025-03-29 22:06:31.687391	{"rackid": 103, "shelf_id": 513, "shelf_number": 5700}	{"rackid": 103, "shelf_id": 513, "shelf_number": 5133}
1648	shelf	UPDATE	514	2025-03-29 22:06:31.687391	{"rackid": 103, "shelf_id": 514, "shelf_number": 5800}	{"rackid": 103, "shelf_id": 514, "shelf_number": 5134}
1649	shelf	UPDATE	515	2025-03-29 22:06:31.687391	{"rackid": 103, "shelf_id": 515, "shelf_number": 5900}	{"rackid": 103, "shelf_id": 515, "shelf_number": 5135}
1650	shelf	UPDATE	516	2025-03-29 22:06:31.687391	{"rackid": 104, "shelf_id": 516, "shelf_number": 5600}	{"rackid": 104, "shelf_id": 516, "shelf_number": 5141}
1651	shelf	UPDATE	517	2025-03-29 22:06:31.687391	{"rackid": 104, "shelf_id": 517, "shelf_number": 5700}	{"rackid": 104, "shelf_id": 517, "shelf_number": 5142}
1652	shelf	UPDATE	518	2025-03-29 22:06:31.687391	{"rackid": 104, "shelf_id": 518, "shelf_number": 5800}	{"rackid": 104, "shelf_id": 518, "shelf_number": 5143}
1653	shelf	UPDATE	519	2025-03-29 22:06:31.687391	{"rackid": 104, "shelf_id": 519, "shelf_number": 5900}	{"rackid": 104, "shelf_id": 519, "shelf_number": 5144}
1654	shelf	UPDATE	520	2025-03-29 22:06:31.687391	{"rackid": 104, "shelf_id": 520, "shelf_number": 6000}	{"rackid": 104, "shelf_id": 520, "shelf_number": 5145}
1655	shelf	UPDATE	521	2025-03-29 22:06:31.687391	{"rackid": 105, "shelf_id": 521, "shelf_number": 5700}	{"rackid": 105, "shelf_id": 521, "shelf_number": 5151}
1656	shelf	UPDATE	522	2025-03-29 22:06:31.687391	{"rackid": 105, "shelf_id": 522, "shelf_number": 5800}	{"rackid": 105, "shelf_id": 522, "shelf_number": 5152}
1657	shelf	UPDATE	523	2025-03-29 22:06:31.687391	{"rackid": 105, "shelf_id": 523, "shelf_number": 5900}	{"rackid": 105, "shelf_id": 523, "shelf_number": 5153}
1658	shelf	UPDATE	524	2025-03-29 22:06:31.687391	{"rackid": 105, "shelf_id": 524, "shelf_number": 6000}	{"rackid": 105, "shelf_id": 524, "shelf_number": 5154}
1659	shelf	UPDATE	525	2025-03-29 22:06:31.687391	{"rackid": 105, "shelf_id": 525, "shelf_number": 6100}	{"rackid": 105, "shelf_id": 525, "shelf_number": 5155}
1660	shelf	UPDATE	526	2025-03-29 22:06:31.687391	{"rackid": 106, "shelf_id": 526, "shelf_number": 5400}	{"rackid": 106, "shelf_id": 526, "shelf_number": 5211}
1661	shelf	UPDATE	527	2025-03-29 22:06:31.687391	{"rackid": 106, "shelf_id": 527, "shelf_number": 5500}	{"rackid": 106, "shelf_id": 527, "shelf_number": 5212}
1662	shelf	UPDATE	528	2025-03-29 22:06:31.687391	{"rackid": 106, "shelf_id": 528, "shelf_number": 5600}	{"rackid": 106, "shelf_id": 528, "shelf_number": 5213}
1663	shelf	UPDATE	529	2025-03-29 22:06:31.687391	{"rackid": 106, "shelf_id": 529, "shelf_number": 5700}	{"rackid": 106, "shelf_id": 529, "shelf_number": 5214}
1664	shelf	UPDATE	530	2025-03-29 22:06:31.687391	{"rackid": 106, "shelf_id": 530, "shelf_number": 5800}	{"rackid": 106, "shelf_id": 530, "shelf_number": 5215}
1665	shelf	UPDATE	531	2025-03-29 22:06:31.687391	{"rackid": 107, "shelf_id": 531, "shelf_number": 5500}	{"rackid": 107, "shelf_id": 531, "shelf_number": 5221}
1666	shelf	UPDATE	532	2025-03-29 22:06:31.687391	{"rackid": 107, "shelf_id": 532, "shelf_number": 5600}	{"rackid": 107, "shelf_id": 532, "shelf_number": 5222}
1667	shelf	UPDATE	533	2025-03-29 22:06:31.687391	{"rackid": 107, "shelf_id": 533, "shelf_number": 5700}	{"rackid": 107, "shelf_id": 533, "shelf_number": 5223}
1668	shelf	UPDATE	534	2025-03-29 22:06:31.687391	{"rackid": 107, "shelf_id": 534, "shelf_number": 5800}	{"rackid": 107, "shelf_id": 534, "shelf_number": 5224}
1669	shelf	UPDATE	535	2025-03-29 22:06:31.687391	{"rackid": 107, "shelf_id": 535, "shelf_number": 5900}	{"rackid": 107, "shelf_id": 535, "shelf_number": 5225}
1670	shelf	UPDATE	536	2025-03-29 22:06:31.687391	{"rackid": 108, "shelf_id": 536, "shelf_number": 5600}	{"rackid": 108, "shelf_id": 536, "shelf_number": 5231}
1671	shelf	UPDATE	537	2025-03-29 22:06:31.687391	{"rackid": 108, "shelf_id": 537, "shelf_number": 5700}	{"rackid": 108, "shelf_id": 537, "shelf_number": 5232}
1672	shelf	UPDATE	538	2025-03-29 22:06:31.687391	{"rackid": 108, "shelf_id": 538, "shelf_number": 5800}	{"rackid": 108, "shelf_id": 538, "shelf_number": 5233}
1673	shelf	UPDATE	539	2025-03-29 22:06:31.687391	{"rackid": 108, "shelf_id": 539, "shelf_number": 5900}	{"rackid": 108, "shelf_id": 539, "shelf_number": 5234}
1674	shelf	UPDATE	540	2025-03-29 22:06:31.687391	{"rackid": 108, "shelf_id": 540, "shelf_number": 6000}	{"rackid": 108, "shelf_id": 540, "shelf_number": 5235}
1675	shelf	UPDATE	541	2025-03-29 22:06:31.687391	{"rackid": 109, "shelf_id": 541, "shelf_number": 5700}	{"rackid": 109, "shelf_id": 541, "shelf_number": 5241}
1676	shelf	UPDATE	542	2025-03-29 22:06:31.687391	{"rackid": 109, "shelf_id": 542, "shelf_number": 5800}	{"rackid": 109, "shelf_id": 542, "shelf_number": 5242}
1677	shelf	UPDATE	543	2025-03-29 22:06:31.687391	{"rackid": 109, "shelf_id": 543, "shelf_number": 5900}	{"rackid": 109, "shelf_id": 543, "shelf_number": 5243}
1678	shelf	UPDATE	544	2025-03-29 22:06:31.687391	{"rackid": 109, "shelf_id": 544, "shelf_number": 6000}	{"rackid": 109, "shelf_id": 544, "shelf_number": 5244}
1679	shelf	UPDATE	545	2025-03-29 22:06:31.687391	{"rackid": 109, "shelf_id": 545, "shelf_number": 6100}	{"rackid": 109, "shelf_id": 545, "shelf_number": 5245}
1680	shelf	UPDATE	546	2025-03-29 22:06:31.687391	{"rackid": 110, "shelf_id": 546, "shelf_number": 5800}	{"rackid": 110, "shelf_id": 546, "shelf_number": 5251}
1681	shelf	UPDATE	547	2025-03-29 22:06:31.687391	{"rackid": 110, "shelf_id": 547, "shelf_number": 5900}	{"rackid": 110, "shelf_id": 547, "shelf_number": 5252}
1682	shelf	UPDATE	548	2025-03-29 22:06:31.687391	{"rackid": 110, "shelf_id": 548, "shelf_number": 6000}	{"rackid": 110, "shelf_id": 548, "shelf_number": 5253}
1683	shelf	UPDATE	549	2025-03-29 22:06:31.687391	{"rackid": 110, "shelf_id": 549, "shelf_number": 6100}	{"rackid": 110, "shelf_id": 549, "shelf_number": 5254}
1684	shelf	UPDATE	550	2025-03-29 22:06:31.687391	{"rackid": 110, "shelf_id": 550, "shelf_number": 6200}	{"rackid": 110, "shelf_id": 550, "shelf_number": 5255}
1685	shelf	UPDATE	551	2025-03-29 22:06:31.687391	{"rackid": 111, "shelf_id": 551, "shelf_number": 5500}	{"rackid": 111, "shelf_id": 551, "shelf_number": 5311}
1686	shelf	UPDATE	552	2025-03-29 22:06:31.687391	{"rackid": 111, "shelf_id": 552, "shelf_number": 5600}	{"rackid": 111, "shelf_id": 552, "shelf_number": 5312}
1687	shelf	UPDATE	553	2025-03-29 22:06:31.687391	{"rackid": 111, "shelf_id": 553, "shelf_number": 5700}	{"rackid": 111, "shelf_id": 553, "shelf_number": 5313}
1688	shelf	UPDATE	554	2025-03-29 22:06:31.687391	{"rackid": 111, "shelf_id": 554, "shelf_number": 5800}	{"rackid": 111, "shelf_id": 554, "shelf_number": 5314}
1689	shelf	UPDATE	555	2025-03-29 22:06:31.687391	{"rackid": 111, "shelf_id": 555, "shelf_number": 5900}	{"rackid": 111, "shelf_id": 555, "shelf_number": 5315}
1690	shelf	UPDATE	556	2025-03-29 22:06:31.687391	{"rackid": 112, "shelf_id": 556, "shelf_number": 5600}	{"rackid": 112, "shelf_id": 556, "shelf_number": 5321}
1691	shelf	UPDATE	557	2025-03-29 22:06:31.687391	{"rackid": 112, "shelf_id": 557, "shelf_number": 5700}	{"rackid": 112, "shelf_id": 557, "shelf_number": 5322}
1692	shelf	UPDATE	558	2025-03-29 22:06:31.687391	{"rackid": 112, "shelf_id": 558, "shelf_number": 5800}	{"rackid": 112, "shelf_id": 558, "shelf_number": 5323}
1693	shelf	UPDATE	559	2025-03-29 22:06:31.687391	{"rackid": 112, "shelf_id": 559, "shelf_number": 5900}	{"rackid": 112, "shelf_id": 559, "shelf_number": 5324}
1694	shelf	UPDATE	560	2025-03-29 22:06:31.687391	{"rackid": 112, "shelf_id": 560, "shelf_number": 6000}	{"rackid": 112, "shelf_id": 560, "shelf_number": 5325}
1695	shelf	UPDATE	561	2025-03-29 22:06:31.687391	{"rackid": 113, "shelf_id": 561, "shelf_number": 5700}	{"rackid": 113, "shelf_id": 561, "shelf_number": 5331}
1696	shelf	UPDATE	562	2025-03-29 22:06:31.687391	{"rackid": 113, "shelf_id": 562, "shelf_number": 5800}	{"rackid": 113, "shelf_id": 562, "shelf_number": 5332}
1697	shelf	UPDATE	563	2025-03-29 22:06:31.687391	{"rackid": 113, "shelf_id": 563, "shelf_number": 5900}	{"rackid": 113, "shelf_id": 563, "shelf_number": 5333}
1698	shelf	UPDATE	564	2025-03-29 22:06:31.687391	{"rackid": 113, "shelf_id": 564, "shelf_number": 6000}	{"rackid": 113, "shelf_id": 564, "shelf_number": 5334}
1699	shelf	UPDATE	565	2025-03-29 22:06:31.687391	{"rackid": 113, "shelf_id": 565, "shelf_number": 6100}	{"rackid": 113, "shelf_id": 565, "shelf_number": 5335}
1700	shelf	UPDATE	566	2025-03-29 22:06:31.687391	{"rackid": 114, "shelf_id": 566, "shelf_number": 5800}	{"rackid": 114, "shelf_id": 566, "shelf_number": 5341}
1701	shelf	UPDATE	567	2025-03-29 22:06:31.687391	{"rackid": 114, "shelf_id": 567, "shelf_number": 5900}	{"rackid": 114, "shelf_id": 567, "shelf_number": 5342}
1702	shelf	UPDATE	568	2025-03-29 22:06:31.687391	{"rackid": 114, "shelf_id": 568, "shelf_number": 6000}	{"rackid": 114, "shelf_id": 568, "shelf_number": 5343}
1703	shelf	UPDATE	569	2025-03-29 22:06:31.687391	{"rackid": 114, "shelf_id": 569, "shelf_number": 6100}	{"rackid": 114, "shelf_id": 569, "shelf_number": 5344}
1704	shelf	UPDATE	570	2025-03-29 22:06:31.687391	{"rackid": 114, "shelf_id": 570, "shelf_number": 6200}	{"rackid": 114, "shelf_id": 570, "shelf_number": 5345}
1705	shelf	UPDATE	571	2025-03-29 22:06:31.687391	{"rackid": 115, "shelf_id": 571, "shelf_number": 5900}	{"rackid": 115, "shelf_id": 571, "shelf_number": 5351}
1706	shelf	UPDATE	572	2025-03-29 22:06:31.687391	{"rackid": 115, "shelf_id": 572, "shelf_number": 6000}	{"rackid": 115, "shelf_id": 572, "shelf_number": 5352}
1707	shelf	UPDATE	573	2025-03-29 22:06:31.687391	{"rackid": 115, "shelf_id": 573, "shelf_number": 6100}	{"rackid": 115, "shelf_id": 573, "shelf_number": 5353}
1708	shelf	UPDATE	574	2025-03-29 22:06:31.687391	{"rackid": 115, "shelf_id": 574, "shelf_number": 6200}	{"rackid": 115, "shelf_id": 574, "shelf_number": 5354}
1709	shelf	UPDATE	575	2025-03-29 22:06:31.687391	{"rackid": 115, "shelf_id": 575, "shelf_number": 6300}	{"rackid": 115, "shelf_id": 575, "shelf_number": 5355}
1710	shelf	UPDATE	576	2025-03-29 22:06:31.687391	{"rackid": 116, "shelf_id": 576, "shelf_number": 5600}	{"rackid": 116, "shelf_id": 576, "shelf_number": 5411}
1711	shelf	UPDATE	577	2025-03-29 22:06:31.687391	{"rackid": 116, "shelf_id": 577, "shelf_number": 5700}	{"rackid": 116, "shelf_id": 577, "shelf_number": 5412}
1712	shelf	UPDATE	578	2025-03-29 22:06:31.687391	{"rackid": 116, "shelf_id": 578, "shelf_number": 5800}	{"rackid": 116, "shelf_id": 578, "shelf_number": 5413}
1713	shelf	UPDATE	579	2025-03-29 22:06:31.687391	{"rackid": 116, "shelf_id": 579, "shelf_number": 5900}	{"rackid": 116, "shelf_id": 579, "shelf_number": 5414}
1714	shelf	UPDATE	580	2025-03-29 22:06:31.687391	{"rackid": 116, "shelf_id": 580, "shelf_number": 6000}	{"rackid": 116, "shelf_id": 580, "shelf_number": 5415}
1715	shelf	UPDATE	581	2025-03-29 22:06:31.687391	{"rackid": 117, "shelf_id": 581, "shelf_number": 5700}	{"rackid": 117, "shelf_id": 581, "shelf_number": 5421}
1716	shelf	UPDATE	582	2025-03-29 22:06:31.687391	{"rackid": 117, "shelf_id": 582, "shelf_number": 5800}	{"rackid": 117, "shelf_id": 582, "shelf_number": 5422}
1717	shelf	UPDATE	583	2025-03-29 22:06:31.687391	{"rackid": 117, "shelf_id": 583, "shelf_number": 5900}	{"rackid": 117, "shelf_id": 583, "shelf_number": 5423}
1718	shelf	UPDATE	584	2025-03-29 22:06:31.687391	{"rackid": 117, "shelf_id": 584, "shelf_number": 6000}	{"rackid": 117, "shelf_id": 584, "shelf_number": 5424}
1719	shelf	UPDATE	585	2025-03-29 22:06:31.687391	{"rackid": 117, "shelf_id": 585, "shelf_number": 6100}	{"rackid": 117, "shelf_id": 585, "shelf_number": 5425}
1720	shelf	UPDATE	586	2025-03-29 22:06:31.687391	{"rackid": 118, "shelf_id": 586, "shelf_number": 5800}	{"rackid": 118, "shelf_id": 586, "shelf_number": 5431}
1721	shelf	UPDATE	587	2025-03-29 22:06:31.687391	{"rackid": 118, "shelf_id": 587, "shelf_number": 5900}	{"rackid": 118, "shelf_id": 587, "shelf_number": 5432}
1722	shelf	UPDATE	588	2025-03-29 22:06:31.687391	{"rackid": 118, "shelf_id": 588, "shelf_number": 6000}	{"rackid": 118, "shelf_id": 588, "shelf_number": 5433}
1723	shelf	UPDATE	589	2025-03-29 22:06:31.687391	{"rackid": 118, "shelf_id": 589, "shelf_number": 6100}	{"rackid": 118, "shelf_id": 589, "shelf_number": 5434}
1724	shelf	UPDATE	590	2025-03-29 22:06:31.687391	{"rackid": 118, "shelf_id": 590, "shelf_number": 6200}	{"rackid": 118, "shelf_id": 590, "shelf_number": 5435}
1725	shelf	UPDATE	591	2025-03-29 22:06:31.687391	{"rackid": 119, "shelf_id": 591, "shelf_number": 5900}	{"rackid": 119, "shelf_id": 591, "shelf_number": 5441}
1726	shelf	UPDATE	592	2025-03-29 22:06:31.687391	{"rackid": 119, "shelf_id": 592, "shelf_number": 6000}	{"rackid": 119, "shelf_id": 592, "shelf_number": 5442}
1727	shelf	UPDATE	593	2025-03-29 22:06:31.687391	{"rackid": 119, "shelf_id": 593, "shelf_number": 6100}	{"rackid": 119, "shelf_id": 593, "shelf_number": 5443}
1728	shelf	UPDATE	594	2025-03-29 22:06:31.687391	{"rackid": 119, "shelf_id": 594, "shelf_number": 6200}	{"rackid": 119, "shelf_id": 594, "shelf_number": 5444}
1729	shelf	UPDATE	595	2025-03-29 22:06:31.687391	{"rackid": 119, "shelf_id": 595, "shelf_number": 6300}	{"rackid": 119, "shelf_id": 595, "shelf_number": 5445}
1730	shelf	UPDATE	596	2025-03-29 22:06:31.687391	{"rackid": 120, "shelf_id": 596, "shelf_number": 6000}	{"rackid": 120, "shelf_id": 596, "shelf_number": 5451}
1731	shelf	UPDATE	597	2025-03-29 22:06:31.687391	{"rackid": 120, "shelf_id": 597, "shelf_number": 6100}	{"rackid": 120, "shelf_id": 597, "shelf_number": 5452}
1732	shelf	UPDATE	598	2025-03-29 22:06:31.687391	{"rackid": 120, "shelf_id": 598, "shelf_number": 6200}	{"rackid": 120, "shelf_id": 598, "shelf_number": 5453}
1733	shelf	UPDATE	599	2025-03-29 22:06:31.687391	{"rackid": 120, "shelf_id": 599, "shelf_number": 6300}	{"rackid": 120, "shelf_id": 599, "shelf_number": 5454}
1734	shelf	UPDATE	600	2025-03-29 22:06:31.687391	{"rackid": 120, "shelf_id": 600, "shelf_number": 6400}	{"rackid": 120, "shelf_id": 600, "shelf_number": 5455}
1735	shelf	UPDATE	601	2025-03-29 22:06:31.687391	{"rackid": 121, "shelf_id": 601, "shelf_number": 5700}	{"rackid": 121, "shelf_id": 601, "shelf_number": 5511}
1736	shelf	UPDATE	602	2025-03-29 22:06:31.687391	{"rackid": 121, "shelf_id": 602, "shelf_number": 5800}	{"rackid": 121, "shelf_id": 602, "shelf_number": 5512}
1737	shelf	UPDATE	603	2025-03-29 22:06:31.687391	{"rackid": 121, "shelf_id": 603, "shelf_number": 5900}	{"rackid": 121, "shelf_id": 603, "shelf_number": 5513}
1738	shelf	UPDATE	604	2025-03-29 22:06:31.687391	{"rackid": 121, "shelf_id": 604, "shelf_number": 6000}	{"rackid": 121, "shelf_id": 604, "shelf_number": 5514}
1739	shelf	UPDATE	605	2025-03-29 22:06:31.687391	{"rackid": 121, "shelf_id": 605, "shelf_number": 6100}	{"rackid": 121, "shelf_id": 605, "shelf_number": 5515}
1740	shelf	UPDATE	606	2025-03-29 22:06:31.687391	{"rackid": 122, "shelf_id": 606, "shelf_number": 5800}	{"rackid": 122, "shelf_id": 606, "shelf_number": 5521}
1741	shelf	UPDATE	607	2025-03-29 22:06:31.687391	{"rackid": 122, "shelf_id": 607, "shelf_number": 5900}	{"rackid": 122, "shelf_id": 607, "shelf_number": 5522}
1742	shelf	UPDATE	608	2025-03-29 22:06:31.687391	{"rackid": 122, "shelf_id": 608, "shelf_number": 6000}	{"rackid": 122, "shelf_id": 608, "shelf_number": 5523}
1743	shelf	UPDATE	609	2025-03-29 22:06:31.687391	{"rackid": 122, "shelf_id": 609, "shelf_number": 6100}	{"rackid": 122, "shelf_id": 609, "shelf_number": 5524}
1744	shelf	UPDATE	610	2025-03-29 22:06:31.687391	{"rackid": 122, "shelf_id": 610, "shelf_number": 6200}	{"rackid": 122, "shelf_id": 610, "shelf_number": 5525}
1745	shelf	UPDATE	611	2025-03-29 22:06:31.687391	{"rackid": 123, "shelf_id": 611, "shelf_number": 5900}	{"rackid": 123, "shelf_id": 611, "shelf_number": 5531}
1746	shelf	UPDATE	612	2025-03-29 22:06:31.687391	{"rackid": 123, "shelf_id": 612, "shelf_number": 6000}	{"rackid": 123, "shelf_id": 612, "shelf_number": 5532}
1747	shelf	UPDATE	613	2025-03-29 22:06:31.687391	{"rackid": 123, "shelf_id": 613, "shelf_number": 6100}	{"rackid": 123, "shelf_id": 613, "shelf_number": 5533}
1748	shelf	UPDATE	614	2025-03-29 22:06:31.687391	{"rackid": 123, "shelf_id": 614, "shelf_number": 6200}	{"rackid": 123, "shelf_id": 614, "shelf_number": 5534}
1749	shelf	UPDATE	615	2025-03-29 22:06:31.687391	{"rackid": 123, "shelf_id": 615, "shelf_number": 6300}	{"rackid": 123, "shelf_id": 615, "shelf_number": 5535}
1750	shelf	UPDATE	616	2025-03-29 22:06:31.687391	{"rackid": 124, "shelf_id": 616, "shelf_number": 6000}	{"rackid": 124, "shelf_id": 616, "shelf_number": 5541}
1751	shelf	UPDATE	617	2025-03-29 22:06:31.687391	{"rackid": 124, "shelf_id": 617, "shelf_number": 6100}	{"rackid": 124, "shelf_id": 617, "shelf_number": 5542}
1752	shelf	UPDATE	618	2025-03-29 22:06:31.687391	{"rackid": 124, "shelf_id": 618, "shelf_number": 6200}	{"rackid": 124, "shelf_id": 618, "shelf_number": 5543}
1753	shelf	UPDATE	619	2025-03-29 22:06:31.687391	{"rackid": 124, "shelf_id": 619, "shelf_number": 6300}	{"rackid": 124, "shelf_id": 619, "shelf_number": 5544}
1754	shelf	UPDATE	620	2025-03-29 22:06:31.687391	{"rackid": 124, "shelf_id": 620, "shelf_number": 6400}	{"rackid": 124, "shelf_id": 620, "shelf_number": 5545}
1755	shelf	UPDATE	621	2025-03-29 22:06:31.687391	{"rackid": 125, "shelf_id": 621, "shelf_number": 6100}	{"rackid": 125, "shelf_id": 621, "shelf_number": 5551}
1756	shelf	UPDATE	622	2025-03-29 22:06:31.687391	{"rackid": 125, "shelf_id": 622, "shelf_number": 6200}	{"rackid": 125, "shelf_id": 622, "shelf_number": 5552}
1757	shelf	UPDATE	623	2025-03-29 22:06:31.687391	{"rackid": 125, "shelf_id": 623, "shelf_number": 6300}	{"rackid": 125, "shelf_id": 623, "shelf_number": 5553}
1758	shelf	UPDATE	624	2025-03-29 22:06:31.687391	{"rackid": 125, "shelf_id": 624, "shelf_number": 6400}	{"rackid": 125, "shelf_id": 624, "shelf_number": 5554}
1759	shelf	UPDATE	625	2025-03-29 22:06:31.687391	{"rackid": 125, "shelf_id": 625, "shelf_number": 6500}	{"rackid": 125, "shelf_id": 625, "shelf_number": 5555}
1765	invoice_employee	UPDATE	12	2025-03-29 22:13:25.074327	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1766	invoice	UPDATE	12	2025-03-29 22:13:29.515911	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1767	invoice_detail	UPDATE	12	2025-03-29 22:13:29.515911	{"detailid": 20, "quantity": 2, "invoiceid": 12}	{"detailid": 20, "quantity": 20, "invoiceid": 12}
1768	invoice_employee	UPDATE	12	2025-03-29 22:13:29.515911	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1769	invoice	UPDATE	12	2025-03-29 22:13:33.323392	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1770	invoice_detail	UPDATE	12	2025-03-29 22:13:33.323392	{"detailid": 20, "quantity": 20, "invoiceid": 12}	{"detailid": 20, "quantity": 1, "invoiceid": 12}
1771	invoice_employee	UPDATE	12	2025-03-29 22:13:33.323392	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1772	invoice	UPDATE	12	2025-03-29 22:16:32.65139	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1773	invoice_detail	UPDATE	12	2025-03-29 22:16:32.65139	{"detailid": 20, "quantity": 1, "invoiceid": 12}	{"detailid": 20, "quantity": 1, "invoiceid": 12}
1774	invoice_employee	UPDATE	12	2025-03-29 22:16:32.65139	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1775	invoice	UPDATE	12	2025-03-29 22:22:15.356393	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1776	invoice_detail	UPDATE	12	2025-03-29 22:22:15.356393	{"detailid": 20, "quantity": 1, "invoiceid": 12}	{"detailid": 20, "quantity": 2, "invoiceid": 12}
1777	invoice_employee	UPDATE	12	2025-03-29 22:22:15.356393	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1778	invoice	UPDATE	12	2025-03-29 22:22:39.542637	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1779	invoice_detail	UPDATE	12	2025-03-29 22:22:39.542637	{"detailid": 20, "quantity": 2, "invoiceid": 12}	{"detailid": 20, "quantity": 1, "invoiceid": 12}
1780	invoice_employee	UPDATE	12	2025-03-29 22:22:39.542637	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1781	invoice	UPDATE	12	2025-03-29 22:23:07.405744	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1782	invoice_detail	UPDATE	12	2025-03-29 22:23:07.405744	{"detailid": 20, "quantity": 1, "invoiceid": 12}	{"detailid": 20, "quantity": 2, "invoiceid": 12}
1783	invoice_employee	UPDATE	12	2025-03-29 22:23:07.405744	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1784	invoice	UPDATE	12	2025-03-29 22:23:12.327605	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1785	invoice_detail	UPDATE	12	2025-03-29 22:23:12.327605	{"detailid": 20, "quantity": 2, "invoiceid": 12}	{"detailid": 20, "quantity": 3, "invoiceid": 12}
1786	invoice_employee	UPDATE	12	2025-03-29 22:23:12.327605	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1787	invoice	UPDATE	12	2025-03-29 22:23:16.418049	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1788	invoice_detail	UPDATE	12	2025-03-29 22:23:16.418049	{"detailid": 20, "quantity": 3, "invoiceid": 12}	{"detailid": 20, "quantity": 4, "invoiceid": 12}
1789	invoice_employee	UPDATE	12	2025-03-29 22:23:16.418049	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1790	invoice	UPDATE	12	2025-03-29 22:23:20.40839	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1791	invoice_detail	UPDATE	12	2025-03-29 22:23:20.40839	{"detailid": 20, "quantity": 4, "invoiceid": 12}	{"detailid": 20, "quantity": 5, "invoiceid": 12}
1792	invoice_employee	UPDATE	12	2025-03-29 22:23:20.40839	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1793	invoice	UPDATE	12	2025-03-29 22:23:24.210636	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1794	invoice_detail	UPDATE	12	2025-03-29 22:23:24.210636	{"detailid": 20, "quantity": 5, "invoiceid": 12}	{"detailid": 20, "quantity": 6, "invoiceid": 12}
1795	invoice_employee	UPDATE	12	2025-03-29 22:23:24.210636	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1796	invoice	UPDATE	12	2025-03-29 22:23:40.105592	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1797	invoice_detail	UPDATE	12	2025-03-29 22:23:40.105592	{"detailid": 20, "quantity": 6, "invoiceid": 12}	{"detailid": 20, "quantity": 7, "invoiceid": 12}
1798	invoice_employee	UPDATE	12	2025-03-29 22:23:40.105592	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1799	invoice	UPDATE	12	2025-03-29 22:23:44.648469	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1800	invoice_detail	UPDATE	12	2025-03-29 22:23:44.648469	{"detailid": 20, "quantity": 7, "invoiceid": 12}	{"detailid": 20, "quantity": 8, "invoiceid": 12}
1801	invoice_employee	UPDATE	12	2025-03-29 22:23:44.648469	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1802	invoice	UPDATE	12	2025-03-29 22:23:49.895355	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1803	invoice_detail	UPDATE	12	2025-03-29 22:23:49.895355	{"detailid": 20, "quantity": 8, "invoiceid": 12}	{"detailid": 20, "quantity": 9, "invoiceid": 12}
1804	invoice_employee	UPDATE	12	2025-03-29 22:23:49.895355	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1877	details	INSERT	46	2025-03-29 23:13:13.270066	\N	{"weight": 2.4, "shelfid": 51, "detail_id": 46, "type_detail": "Аккумулятор"}
1805	invoice	UPDATE	12	2025-03-29 22:23:53.744965	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1806	invoice_detail	UPDATE	12	2025-03-29 22:23:53.744965	{"detailid": 20, "quantity": 9, "invoiceid": 12}	{"detailid": 20, "quantity": 10, "invoiceid": 12}
1807	invoice_employee	UPDATE	12	2025-03-29 22:23:53.744965	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1808	invoice	UPDATE	12	2025-03-29 22:27:17.914169	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1809	invoice_detail	UPDATE	12	2025-03-29 22:27:17.914169	{"detailid": 20, "quantity": 10, "invoiceid": 12}	{"detailid": 20, "quantity": 1, "invoiceid": 12}
1810	invoice_employee	UPDATE	12	2025-03-29 22:27:17.914169	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1811	invoice	UPDATE	12	2025-03-29 22:27:22.591766	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1812	invoice_detail	UPDATE	12	2025-03-29 22:27:22.591766	{"detailid": 20, "quantity": 1, "invoiceid": 12}	{"detailid": 20, "quantity": 2, "invoiceid": 12}
1813	invoice_employee	UPDATE	12	2025-03-29 22:27:22.591766	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1814	invoice	UPDATE	12	2025-03-29 22:30:06.918547	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}	{"status": false, "date_time": "2025-03-29T22:13:00", "invoice_id": 12, "type_invoice": false, "counteragentid": 5}
1815	invoice_detail	UPDATE	12	2025-03-29 22:30:06.918547	{"detailid": 20, "quantity": 2, "invoiceid": 12}	{"detailid": 20, "quantity": 1, "invoiceid": 12}
1816	invoice_employee	UPDATE	12	2025-03-29 22:30:06.918547	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}	{"invoiceid": 12, "responsible": 3, "when_granted": "2025-03-29T22:13:00.411972", "granted_access": 3}
1817	invoice	UPDATE	1	2025-03-29 22:33:34.782218	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
1818	invoice_detail	UPDATE	1	2025-03-29 22:33:34.782218	{"detailid": 6, "quantity": 10, "invoiceid": 1}	{"detailid": 11, "quantity": 9, "invoiceid": 1}
1819	invoice_employee	UPDATE	1	2025-03-29 22:33:34.782218	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}
1820	invoice	UPDATE	1	2025-03-29 22:33:54.149106	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
1821	invoice_detail	UPDATE	1	2025-03-29 22:33:54.149106	{"detailid": 11, "quantity": 9, "invoiceid": 1}	{"detailid": 11, "quantity": 8, "invoiceid": 1}
1822	invoice_employee	UPDATE	1	2025-03-29 22:33:54.149106	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}
1823	invoice	UPDATE	1	2025-03-29 22:33:59.123634	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
1824	invoice_detail	UPDATE	1	2025-03-29 22:33:59.123634	{"detailid": 11, "quantity": 8, "invoiceid": 1}	{"detailid": 11, "quantity": 7, "invoiceid": 1}
1825	invoice_employee	UPDATE	1	2025-03-29 22:33:59.123634	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}
1826	invoice	UPDATE	1	2025-03-29 22:34:03.882421	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
1827	invoice_detail	UPDATE	1	2025-03-29 22:34:03.882421	{"detailid": 11, "quantity": 7, "invoiceid": 1}	{"detailid": 11, "quantity": 6, "invoiceid": 1}
1828	invoice_employee	UPDATE	1	2025-03-29 22:34:03.882421	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}
1829	invoice	UPDATE	1	2025-03-29 22:34:08.335364	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
1830	invoice_detail	UPDATE	1	2025-03-29 22:34:08.335364	{"detailid": 11, "quantity": 6, "invoiceid": 1}	{"detailid": 11, "quantity": 5, "invoiceid": 1}
1831	invoice_employee	UPDATE	1	2025-03-29 22:34:08.335364	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}
1832	invoice	UPDATE	1	2025-03-29 22:34:13.020928	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
1833	invoice_detail	UPDATE	1	2025-03-29 22:34:13.020928	{"detailid": 11, "quantity": 5, "invoiceid": 1}	{"detailid": 11, "quantity": 4, "invoiceid": 1}
1834	invoice_employee	UPDATE	1	2025-03-29 22:34:13.020928	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}
1835	invoice	UPDATE	1	2025-03-29 22:34:18.106784	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
1836	invoice_detail	UPDATE	1	2025-03-29 22:34:18.106784	{"detailid": 11, "quantity": 4, "invoiceid": 1}	{"detailid": 11, "quantity": 3, "invoiceid": 1}
1837	invoice_employee	UPDATE	1	2025-03-29 22:34:18.106784	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}
1838	invoice	UPDATE	1	2025-03-29 22:34:21.985293	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
1839	invoice_detail	UPDATE	1	2025-03-29 22:34:21.985293	{"detailid": 11, "quantity": 3, "invoiceid": 1}	{"detailid": 11, "quantity": 2, "invoiceid": 1}
1840	invoice_employee	UPDATE	1	2025-03-29 22:34:21.985293	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}
1841	invoice	UPDATE	1	2025-03-29 22:34:29.566145	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
1842	invoice_detail	UPDATE	1	2025-03-29 22:34:29.566145	{"detailid": 11, "quantity": 2, "invoiceid": 1}	{"detailid": 11, "quantity": 1, "invoiceid": 1}
1843	invoice_employee	UPDATE	1	2025-03-29 22:34:29.566145	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}
1844	invoice	UPDATE	3	2025-03-29 22:34:34.422069	{"status": true, "date_time": "2025-03-03T14:45:00", "invoice_id": 3, "type_invoice": true, "counteragentid": 3}	{"status": true, "date_time": "2025-03-03T14:45:00", "invoice_id": 3, "type_invoice": true, "counteragentid": 3}
1845	invoice_detail	UPDATE	3	2025-03-29 22:34:34.422069	{"detailid": 3, "quantity": 20, "invoiceid": 3}	{"detailid": 3, "quantity": 1, "invoiceid": 3}
1846	invoice_employee	UPDATE	3	2025-03-29 22:34:34.422069	{"invoiceid": 3, "responsible": 2, "when_granted": "2025-03-03T14:50:00", "granted_access": 5}	{"invoiceid": 3, "responsible": 2, "when_granted": "2025-03-03T14:50:00", "granted_access": 5}
1847	invoice	UPDATE	7	2025-03-29 22:35:04.019537	{"status": false, "date_time": "2025-03-28T01:37:00", "invoice_id": 7, "type_invoice": false, "counteragentid": 3}	{"status": false, "date_time": "2025-03-28T01:37:00", "invoice_id": 7, "type_invoice": false, "counteragentid": 3}
1848	invoice_detail	UPDATE	7	2025-03-29 22:35:04.019537	{"detailid": 39, "quantity": 12, "invoiceid": 7}	{"detailid": 39, "quantity": 1, "invoiceid": 7}
1849	invoice_employee	UPDATE	7	2025-03-29 22:35:04.019537	{"invoiceid": 7, "responsible": 2, "when_granted": "2025-03-28T01:36:18.328025", "granted_access": 2}	{"invoiceid": 7, "responsible": 2, "when_granted": "2025-03-28T01:36:18.328025", "granted_access": 2}
1850	invoice_detail	DELETE	9	2025-03-29 22:35:22.201103	{"detailid": 4, "quantity": 10, "invoiceid": 9}	\N
1851	invoice_employee	DELETE	9	2025-03-29 22:35:22.201103	{"invoiceid": 9, "responsible": 2, "when_granted": "2025-03-28T02:00:43.000485", "granted_access": 2}	\N
1852	invoice	DELETE	9	2025-03-29 22:35:22.201103	{"status": false, "date_time": "2025-03-28T02:00:00", "invoice_id": 9, "type_invoice": false, "counteragentid": 2}	\N
1853	invoice	UPDATE	6	2025-03-29 22:35:32.428191	{"status": false, "date_time": "2025-03-28T01:33:00", "invoice_id": 6, "type_invoice": false, "counteragentid": 1}	{"status": false, "date_time": "2025-03-28T01:33:00", "invoice_id": 6, "type_invoice": false, "counteragentid": 1}
1854	invoice_detail	UPDATE	6	2025-03-29 22:35:32.428191	{"detailid": 26, "quantity": 10, "invoiceid": 6}	{"detailid": 26, "quantity": 1, "invoiceid": 6}
1855	invoice_employee	UPDATE	6	2025-03-29 22:35:32.428191	{"invoiceid": 6, "responsible": 1, "when_granted": "2025-03-28T01:33:02.845495", "granted_access": 1}	{"invoiceid": 6, "responsible": 1, "when_granted": "2025-03-28T01:33:02.845495", "granted_access": 1}
1856	invoice	UPDATE	5	2025-03-29 22:35:36.731923	{"status": true, "date_time": "2025-03-05T15:00:00", "invoice_id": 5, "type_invoice": true, "counteragentid": 5}	{"status": true, "date_time": "2025-03-05T15:00:00", "invoice_id": 5, "type_invoice": true, "counteragentid": 5}
1857	invoice_detail	UPDATE	5	2025-03-29 22:35:36.731923	{"detailid": 5, "quantity": 15, "invoiceid": 5}	{"detailid": 5, "quantity": 1, "invoiceid": 5}
1858	invoice_employee	UPDATE	5	2025-03-29 22:35:36.731923	{"invoiceid": 5, "responsible": 5, "when_granted": "2025-03-05T15:05:00", "granted_access": 3}	{"invoiceid": 5, "responsible": 5, "when_granted": "2025-03-05T15:05:00", "granted_access": 3}
1859	invoice	UPDATE	4	2025-03-29 22:35:40.281909	{"status": false, "date_time": "2025-03-04T11:20:00", "invoice_id": 4, "type_invoice": false, "counteragentid": 4}	{"status": false, "date_time": "2025-03-04T11:20:00", "invoice_id": 4, "type_invoice": false, "counteragentid": 4}
1860	invoice_detail	UPDATE	4	2025-03-29 22:35:40.281909	{"detailid": 4, "quantity": 7, "invoiceid": 4}	{"detailid": 4, "quantity": 1, "invoiceid": 4}
1861	invoice_employee	UPDATE	4	2025-03-29 22:35:40.281909	{"invoiceid": 4, "responsible": 4, "when_granted": "2025-03-04T11:25:00", "granted_access": 1}	{"invoiceid": 4, "responsible": 4, "when_granted": "2025-03-04T11:25:00", "granted_access": 1}
1862	invoice	UPDATE	2	2025-03-29 22:35:43.398152	{"status": false, "date_time": "2025-03-02T10:30:00", "invoice_id": 2, "type_invoice": false, "counteragentid": 2}	{"status": false, "date_time": "2025-03-02T10:30:00", "invoice_id": 2, "type_invoice": false, "counteragentid": 2}
1863	invoice_detail	UPDATE	2	2025-03-29 22:35:43.398152	{"detailid": 2, "quantity": 5, "invoiceid": 2}	{"detailid": 2, "quantity": 1, "invoiceid": 2}
1864	invoice_employee	UPDATE	2	2025-03-29 22:35:43.398152	{"invoiceid": 2, "responsible": 3, "when_granted": "2025-03-02T10:35:00", "granted_access": 4}	{"invoiceid": 2, "responsible": 3, "when_granted": "2025-03-02T10:35:00", "granted_access": 4}
1865	invoice	UPDATE	1	2025-03-29 22:35:46.996619	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}	{"status": false, "date_time": "2025-03-01T09:00:00", "invoice_id": 1, "type_invoice": true, "counteragentid": 1}
1866	invoice_detail	UPDATE	1	2025-03-29 22:35:46.996619	{"detailid": 11, "quantity": 1, "invoiceid": 1}	{"detailid": 11, "quantity": 3, "invoiceid": 1}
1867	invoice_employee	UPDATE	1	2025-03-29 22:35:46.996619	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}	{"invoiceid": 1, "responsible": 1, "when_granted": "2025-03-01T09:05:00", "granted_access": 2}
1868	invoice	UPDATE	2	2025-03-29 22:36:04.887172	{"status": false, "date_time": "2025-03-02T10:30:00", "invoice_id": 2, "type_invoice": false, "counteragentid": 2}	{"status": false, "date_time": "2025-03-02T10:30:00", "invoice_id": 2, "type_invoice": false, "counteragentid": 2}
1869	invoice_detail	UPDATE	2	2025-03-29 22:36:04.887172	{"detailid": 2, "quantity": 1, "invoiceid": 2}	{"detailid": 2, "quantity": 2, "invoiceid": 2}
1870	invoice_employee	UPDATE	2	2025-03-29 22:36:04.887172	{"invoiceid": 2, "responsible": 3, "when_granted": "2025-03-02T10:35:00", "granted_access": 4}	{"invoiceid": 2, "responsible": 3, "when_granted": "2025-03-02T10:35:00", "granted_access": 4}
1871	invoice	UPDATE	4	2025-03-29 22:36:17.503215	{"status": false, "date_time": "2025-03-04T11:20:00", "invoice_id": 4, "type_invoice": false, "counteragentid": 4}	{"status": false, "date_time": "2025-03-04T11:20:00", "invoice_id": 4, "type_invoice": false, "counteragentid": 4}
1872	invoice_detail	UPDATE	4	2025-03-29 22:36:17.503215	{"detailid": 4, "quantity": 1, "invoiceid": 4}	{"detailid": 4, "quantity": 2, "invoiceid": 4}
1873	invoice_employee	UPDATE	4	2025-03-29 22:36:17.503215	{"invoiceid": 4, "responsible": 4, "when_granted": "2025-03-04T11:25:00", "granted_access": 1}	{"invoiceid": 4, "responsible": 4, "when_granted": "2025-03-04T11:25:00", "granted_access": 1}
1874	invoice	UPDATE	5	2025-03-29 22:36:35.955203	{"status": true, "date_time": "2025-03-05T15:00:00", "invoice_id": 5, "type_invoice": true, "counteragentid": 5}	{"status": true, "date_time": "2025-03-05T15:00:00", "invoice_id": 5, "type_invoice": true, "counteragentid": 5}
1875	invoice_detail	UPDATE	5	2025-03-29 22:36:35.955203	{"detailid": 5, "quantity": 1, "invoiceid": 5}	{"detailid": 5, "quantity": 2, "invoiceid": 5}
1876	invoice_employee	UPDATE	5	2025-03-29 22:36:35.955203	{"invoiceid": 5, "responsible": 5, "when_granted": "2025-03-05T15:05:00", "granted_access": 3}	{"invoiceid": 5, "responsible": 5, "when_granted": "2025-03-05T15:05:00", "granted_access": 3}
1879	details	INSERT	14	2025-03-29 23:19:00.471716	\N	{"weight": 7.3, "shelfid": 24, "detail_id": 14, "type_detail": "Фары"}
1880	details	UNDO	1878	2025-03-29 23:19:00.471716	\N	{"weight": 7.3, "shelfid": 24, "detail_id": 14, "type_detail": "Фары"}
1881	details	DELETE	9	2025-03-29 23:23:17.6947	{"weight": 7.3, "shelfid": 19, "detail_id": 9, "type_detail": "Фары"}	\N
1882	details	INSERT	9	2025-03-29 23:23:28.716011	\N	{"weight": 7.3, "shelfid": 19, "detail_id": 9, "type_detail": "Фары"}
1883	details	UNDO	1881	2025-03-29 23:23:28.716011	\N	{"weight": 7.3, "shelfid": 19, "detail_id": 9, "type_detail": "Фары"}
1884	details	DELETE	46	2025-03-29 23:23:31.058514	{"weight": 2.4, "shelfid": 51, "detail_id": 46, "type_detail": "Аккумулятор"}	\N
1885	details	INSERT	46	2025-03-29 23:23:51.073769	\N	{"weight": 2.4, "shelfid": 51, "detail_id": 46, "type_detail": "Аккумулятор"}
1886	details	UNDO	1884	2025-03-29 23:23:51.073769	\N	{"weight": 2.4, "shelfid": 51, "detail_id": 46, "type_detail": "Аккумулятор"}
1887	details	DELETE	46	2025-03-29 23:28:28.175583	{"weight": 2.4, "shelfid": 51, "detail_id": 46, "type_detail": "Аккумулятор"}	\N
1888	details	INSERT	46	2025-03-29 23:28:42.492387	\N	{"weight": 2.4, "shelfid": 51, "detail_id": 46, "type_detail": "Аккумулятор"}
1889	details	UNDO	1887	2025-03-29 23:28:42.492387	\N	{"weight": 2.4, "shelfid": 51, "detail_id": 46, "type_detail": "Аккумулятор"}
1890	details	DELETE	46	2025-03-29 23:28:49.088325	{"weight": 2.4, "shelfid": 51, "detail_id": 46, "type_detail": "Аккумулятор"}	\N
1891	SYSTEM	ROLLBACK	3	2025-03-29 23:28:49.088325	\N	\N
1894	details	UPDATE	1	2025-03-29 23:46:41.355695	{"weight": 12, "shelfid": 31, "detail_id": 1, "type_detail": "Двигатель"}	{"weight": 12, "shelfid": 1, "detail_id": 1, "type_detail": "Двигатель"}
1895	details	UPDATE	3	2025-03-29 23:46:45.799495	{"weight": 20.7, "shelfid": 3, "detail_id": 3, "type_detail": "Подвеска"}	{"weight": 20.7, "shelfid": 1, "detail_id": 3, "type_detail": "Подвеска"}
1892	details	UPDATE	1	2025-03-29 23:46:27.633814	{"weight": 12, "shelfid": 31, "detail_id": 1, "type_detail": "Двигатель"}	{"weight": 12, "shelfid": 31, "detail_id": 1, "type_detail": "Двигатель"}
1893	details	UPDATE	2	2025-03-29 23:46:34.338518	{"weight": 5, "shelfid": 2, "detail_id": 2, "type_detail": "Тормозные колодки"}	{"weight": 5, "shelfid": 2, "detail_id": 2, "type_detail": "Тормозные колодки"}
1896	details	UPDATE	2	2025-03-29 23:46:53.053437	{"weight": 5, "shelfid": 2, "detail_id": 2, "type_detail": "Тормозные колодки"}	{"weight": 5, "shelfid": 1, "detail_id": 2, "type_detail": "Тормозные колодки"}
1897	details	UPDATE	4	2025-03-29 23:46:57.422129	{"weight": 7.3, "shelfid": 4, "detail_id": 4, "type_detail": "Фары"}	{"weight": 7.3, "shelfid": 1, "detail_id": 4, "type_detail": "Фары"}
1898	details	UPDATE	4	2025-03-29 23:47:03.119769	{"weight": 7.3, "shelfid": 1, "detail_id": 4, "type_detail": "Фары"}	{"weight": 7.3, "shelfid": 4, "detail_id": 4, "type_detail": "Фары"}
1899	details	UPDATE	2	2025-03-29 23:47:03.119769	{"weight": 5, "shelfid": 1, "detail_id": 2, "type_detail": "Тормозные колодки"}	{"weight": 5, "shelfid": 2, "detail_id": 2, "type_detail": "Тормозные колодки"}
1900	details	UPDATE	3	2025-03-29 23:47:03.119769	{"weight": 20.7, "shelfid": 1, "detail_id": 3, "type_detail": "Подвеска"}	{"weight": 20.7, "shelfid": 3, "detail_id": 3, "type_detail": "Подвеска"}
1901	details	UPDATE	1	2025-03-29 23:47:03.119769	{"weight": 12, "shelfid": 1, "detail_id": 1, "type_detail": "Двигатель"}	{"weight": 12, "shelfid": 31, "detail_id": 1, "type_detail": "Двигатель"}
1902	details	UPDATE	2	2025-03-29 23:47:03.119769	{"weight": 5, "shelfid": 2, "detail_id": 2, "type_detail": "Тормозные колодки"}	{"weight": 5, "shelfid": 2, "detail_id": 2, "type_detail": "Тормозные колодки"}
1903	details	UPDATE	1	2025-03-29 23:47:03.119769	{"weight": 12, "shelfid": 31, "detail_id": 1, "type_detail": "Двигатель"}	{"weight": 12, "shelfid": 31, "detail_id": 1, "type_detail": "Двигатель"}
1904	SYSTEM	ROLLBACK	6	2025-03-29 23:47:03.119769	\N	\N
\.


--
-- Data for Name: rack; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.rack (rack_id, roomid, rack_number) FROM stdin;
1	1	111
2	1	112
3	1	113
4	1	114
5	1	115
6	2	121
7	2	122
8	2	123
9	2	124
10	2	125
11	3	131
12	3	132
13	3	133
14	3	134
15	3	135
16	4	141
17	4	142
18	4	143
19	4	144
20	4	145
21	5	151
22	5	152
23	5	153
24	5	154
25	5	155
26	6	211
27	6	212
28	6	213
29	6	214
30	6	215
31	7	221
32	7	222
33	7	223
34	7	224
35	7	225
36	8	231
37	8	232
38	8	233
39	8	234
40	8	235
41	9	241
42	9	242
43	9	243
44	9	244
45	9	245
46	10	251
47	10	252
48	10	253
49	10	254
50	10	255
51	11	311
52	11	312
53	11	313
54	11	314
55	11	315
56	12	321
57	12	322
58	12	323
59	12	324
60	12	325
61	13	331
62	13	332
63	13	333
64	13	334
65	13	335
66	14	341
67	14	342
68	14	343
69	14	344
70	14	345
71	15	351
72	15	352
73	15	353
74	15	354
75	15	355
76	16	411
77	16	412
78	16	413
79	16	414
80	16	415
81	17	421
82	17	422
83	17	423
84	17	424
85	17	425
86	18	431
87	18	432
88	18	433
89	18	434
90	18	435
91	19	441
92	19	442
93	19	443
94	19	444
95	19	445
96	20	451
97	20	452
98	20	453
99	20	454
100	20	455
101	21	511
102	21	512
103	21	513
104	21	514
105	21	515
106	22	521
107	22	522
108	22	523
109	22	524
110	22	525
111	23	531
112	23	532
113	23	533
114	23	534
115	23	535
116	24	541
117	24	542
118	24	543
119	24	544
120	24	545
121	25	551
122	25	552
123	25	553
124	25	554
125	25	555
126	26	611
\.


--
-- Data for Name: room; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.room (room_id, warehouseid, room_number) FROM stdin;
1	1	11
2	1	12
3	1	13
4	1	14
5	1	15
6	2	21
7	2	22
8	2	23
9	2	24
10	2	25
12	3	32
13	3	33
14	3	34
15	3	35
16	4	41
17	4	42
18	4	43
19	4	44
20	4	45
11	3	31
21	5	51
22	5	52
23	5	53
24	5	54
25	5	55
26	8	61
\.


--
-- Data for Name: shelf; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.shelf (shelf_id, rackid, shelf_number) FROM stdin;
71	15	1351
72	15	1352
73	15	1353
74	15	1354
75	15	1355
76	16	1411
77	16	1412
78	16	1413
79	16	1414
80	16	1415
81	17	1421
82	17	1422
83	17	1423
84	17	1424
85	17	1425
86	18	1431
87	18	1432
88	18	1433
89	18	1434
90	18	1435
91	19	1441
92	19	1442
93	19	1443
94	19	1444
95	19	1445
96	20	1451
97	20	1452
98	20	1453
99	20	1454
100	20	1455
101	21	1511
102	21	1512
103	21	1513
104	21	1514
105	21	1515
106	22	1521
107	22	1522
108	22	1523
109	22	1524
110	22	1525
111	23	1531
112	23	1532
113	23	1533
114	23	1534
115	23	1535
116	24	1541
117	24	1542
118	24	1543
119	24	1544
120	24	1545
121	25	1551
122	25	1552
123	25	1553
124	25	1554
125	25	1555
126	26	2111
127	26	2112
128	26	2113
129	26	2114
130	26	2115
131	27	2121
132	27	2122
133	27	2123
134	27	2124
135	27	2125
136	28	2131
137	28	2132
138	28	2133
139	28	2134
140	28	2135
141	29	2141
142	29	2142
143	29	2143
144	29	2144
145	29	2145
146	30	2151
147	30	2152
148	30	2153
149	30	2154
150	30	2155
151	31	2211
152	31	2212
153	31	2213
154	31	2214
155	31	2215
156	32	2221
157	32	2222
158	32	2223
159	32	2224
160	32	2225
161	33	2231
162	33	2232
163	33	2233
164	33	2234
165	33	2235
166	34	2241
167	34	2242
168	34	2243
169	34	2244
170	34	2245
171	35	2251
172	35	2252
173	35	2253
174	35	2254
175	35	2255
176	36	2311
177	36	2312
178	36	2313
179	36	2314
180	36	2315
181	37	2321
182	37	2322
183	37	2323
184	37	2324
185	37	2325
186	38	2331
187	38	2332
188	38	2333
189	38	2334
190	38	2335
191	39	2341
192	39	2342
193	39	2343
194	39	2344
195	39	2345
196	40	2351
197	40	2352
198	40	2353
199	40	2354
200	40	2355
201	41	2411
202	41	2412
203	41	2413
204	41	2414
205	41	2415
206	42	2421
207	42	2422
208	42	2423
209	42	2424
210	42	2425
211	43	2431
212	43	2432
213	43	2433
214	43	2434
215	43	2435
216	44	2441
217	44	2442
218	44	2443
219	44	2444
220	44	2445
221	45	2451
222	45	2452
223	45	2453
224	45	2454
225	45	2455
226	46	2511
227	46	2512
228	46	2513
229	46	2514
230	46	2515
231	47	2521
232	47	2522
233	47	2523
234	47	2524
235	47	2525
236	48	2531
237	48	2532
238	48	2533
239	48	2534
240	48	2535
241	49	2541
242	49	2542
243	49	2543
244	49	2544
245	49	2545
246	50	2551
247	50	2552
248	50	2553
249	50	2554
250	50	2555
251	51	3111
252	51	3112
253	51	3113
254	51	3114
255	51	3115
256	52	3121
257	52	3122
258	52	3123
259	52	3124
260	52	3125
261	53	3131
262	53	3132
263	53	3133
264	53	3134
265	53	3135
266	54	3141
267	54	3142
268	54	3143
269	54	3144
270	54	3145
271	55	3151
272	55	3152
273	55	3153
274	55	3154
275	55	3155
276	56	3211
277	56	3212
278	56	3213
279	56	3214
280	56	3215
281	57	3221
282	57	3222
283	57	3223
284	57	3224
285	57	3225
286	58	3231
287	58	3232
288	58	3233
289	58	3234
290	58	3235
291	59	3241
292	59	3242
293	59	3243
294	59	3244
295	59	3245
296	60	3251
297	60	3252
298	60	3253
299	60	3254
300	60	3255
301	61	3311
302	61	3312
303	61	3313
304	61	3314
305	61	3315
306	62	3321
307	62	3322
308	62	3323
309	62	3324
310	62	3325
311	63	3331
312	63	3332
313	63	3333
314	63	3334
315	63	3335
316	64	3341
317	64	3342
318	64	3343
319	64	3344
320	64	3345
321	65	3351
322	65	3352
323	65	3353
324	65	3354
325	65	3355
326	66	3411
327	66	3412
328	66	3413
329	66	3414
330	66	3415
331	67	3421
332	67	3422
333	67	3423
334	67	3424
335	67	3425
336	68	3431
337	68	3432
338	68	3433
339	68	3434
340	68	3435
341	69	3441
342	69	3442
343	69	3443
344	69	3444
345	69	3445
346	70	3451
347	70	3452
348	70	3453
349	70	3454
350	70	3455
351	71	3511
352	71	3512
353	71	3513
354	71	3514
355	71	3515
356	72	3521
357	72	3522
358	72	3523
359	72	3524
360	72	3525
361	73	3531
362	73	3532
363	73	3533
364	73	3534
365	73	3535
366	74	3541
367	74	3542
368	74	3543
369	74	3544
370	74	3545
371	75	3551
372	75	3552
373	75	3553
374	75	3554
375	75	3555
376	76	4111
377	76	4112
378	76	4113
379	76	4114
380	76	4115
381	77	4121
382	77	4122
383	77	4123
384	77	4124
385	77	4125
386	78	4131
387	78	4132
388	78	4133
389	78	4134
390	78	4135
391	79	4141
392	79	4142
393	79	4143
394	79	4144
395	79	4145
396	80	4151
397	80	4152
398	80	4153
399	80	4154
400	80	4155
401	81	4211
402	81	4212
403	81	4213
404	81	4214
405	81	4215
406	82	4221
407	82	4222
408	82	4223
409	82	4224
410	82	4225
411	83	4231
412	83	4232
413	83	4233
414	83	4234
415	83	4235
416	84	4241
417	84	4242
418	84	4243
419	84	4244
420	84	4245
421	85	4251
422	85	4252
423	85	4253
424	85	4254
425	85	4255
426	86	4311
427	86	4312
428	86	4313
429	86	4314
430	86	4315
431	87	4321
432	87	4322
433	87	4323
434	87	4324
435	87	4325
436	88	4331
437	88	4332
438	88	4333
439	88	4334
440	88	4335
441	89	4341
442	89	4342
443	89	4343
444	89	4344
445	89	4345
446	90	4351
447	90	4352
448	90	4353
449	90	4354
450	90	4355
451	91	4411
452	91	4412
453	91	4413
454	91	4414
455	91	4415
456	92	4421
457	92	4422
458	92	4423
459	92	4424
460	92	4425
461	93	4431
462	93	4432
463	93	4433
464	93	4434
465	93	4435
466	94	4441
467	94	4442
468	94	4443
469	94	4444
470	94	4445
471	95	4451
472	95	4452
473	95	4453
474	95	4454
475	95	4455
476	96	4511
477	96	4512
478	96	4513
479	96	4514
480	96	4515
481	97	4521
482	97	4522
483	97	4523
484	97	4524
485	97	4525
531	107	5221
532	107	5222
533	107	5223
534	107	5224
535	107	5225
536	108	5231
537	108	5232
538	108	5233
539	108	5234
540	108	5235
541	109	5241
542	109	5242
543	109	5243
544	109	5244
545	109	5245
546	110	5251
547	110	5252
548	110	5253
549	110	5254
550	110	5255
551	111	5311
552	111	5312
553	111	5313
554	111	5314
555	111	5315
556	112	5321
557	112	5322
558	112	5323
559	112	5324
560	112	5325
561	113	5331
562	113	5332
563	113	5333
564	113	5334
565	113	5335
566	114	5341
567	114	5342
568	114	5343
569	114	5344
570	114	5345
571	115	5351
572	115	5352
573	115	5353
574	115	5354
575	115	5355
576	116	5411
577	116	5412
578	116	5413
579	116	5414
580	116	5415
581	117	5421
582	117	5422
583	117	5423
584	117	5424
585	117	5425
586	118	5431
587	118	5432
588	118	5433
589	118	5434
590	118	5435
591	119	5441
592	119	5442
593	119	5443
594	119	5444
595	119	5445
596	120	5451
597	120	5452
598	120	5453
599	120	5454
600	120	5455
601	121	5511
602	121	5512
603	121	5513
604	121	5514
605	121	5515
606	122	5521
607	122	5522
608	122	5523
609	122	5524
610	122	5525
611	123	5531
612	123	5532
613	123	5533
614	123	5534
615	123	5535
616	124	5541
617	124	5542
618	124	5543
619	124	5544
620	124	5545
621	125	5551
622	125	5552
623	125	5553
624	125	5554
625	125	5555
1	1	1111
2	1	1112
3	1	1113
4	1	1114
5	1	1115
6	2	1121
7	2	1122
8	2	1123
9	2	1124
10	2	1125
11	3	1131
12	3	1132
13	3	1133
14	3	1134
15	3	1135
16	4	1141
17	4	1142
18	4	1143
19	4	1144
20	4	1145
21	5	1151
22	5	1152
23	5	1153
24	5	1154
25	5	1155
26	6	1211
27	6	1212
28	6	1213
29	6	1214
30	6	1215
31	7	1221
32	7	1222
33	7	1223
34	7	1224
35	7	1225
36	8	1231
37	8	1232
38	8	1233
39	8	1234
40	8	1235
41	9	1241
42	9	1242
43	9	1243
44	9	1244
45	9	1245
46	10	1251
47	10	1252
48	10	1253
49	10	1254
50	10	1255
51	11	1311
52	11	1312
53	11	1313
54	11	1314
55	11	1315
56	12	1321
57	12	1322
58	12	1323
59	12	1324
60	12	1325
61	13	1331
62	13	1332
63	13	1333
64	13	1334
65	13	1335
66	14	1341
67	14	1342
68	14	1343
69	14	1344
70	14	1345
486	98	4531
487	98	4532
488	98	4533
489	98	4534
490	98	4535
491	99	4541
492	99	4542
493	99	4543
494	99	4544
495	99	4545
496	100	4551
497	100	4552
498	100	4553
499	100	4554
500	100	4555
501	101	5111
502	101	5112
503	101	5113
504	101	5114
505	101	5115
506	102	5121
507	102	5122
508	102	5123
509	102	5124
510	102	5125
511	103	5131
512	103	5132
513	103	5133
514	103	5134
515	103	5135
516	104	5141
517	104	5142
518	104	5143
519	104	5144
520	104	5145
521	105	5151
522	105	5152
523	105	5153
524	105	5154
525	105	5155
526	106	5211
527	106	5212
528	106	5213
529	106	5214
530	106	5215
\.


--
-- Data for Name: warehouse; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.warehouse (warehouse_id, warehouse_number, address) FROM stdin;
1	101	ул. Дубовая, 1234, Город A
2	102	ул. Кленовая, 5678, Город B
3	103	ул. Сосновая, 9101, Город C
4	104	ул. Кедровая, 1213, Город D
5	105	ул. Вязовая, 1415, Город E
8	106	ул. Красная, 124, Батайск
\.


--
-- Name: counteragent_counteragent_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.counteragent_counteragent_id_seq', 6, true);


--
-- Name: details_detail_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.details_detail_id_seq', 46, true);


--
-- Name: details_shelfid_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.details_shelfid_seq', 1, false);


--
-- Name: employee_employee_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.employee_employee_id_seq', 6, true);


--
-- Name: invoice_counteragentid_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.invoice_counteragentid_seq', 1, false);


--
-- Name: invoice_detail_detailid_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.invoice_detail_detailid_seq', 1, false);


--
-- Name: invoice_detail_invoiceid_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.invoice_detail_invoiceid_seq', 1, false);


--
-- Name: invoice_employee_granted_access_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.invoice_employee_granted_access_seq', 1, false);


--
-- Name: invoice_employee_invoiceid_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.invoice_employee_invoiceid_seq', 1, false);


--
-- Name: invoice_employee_responsible_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.invoice_employee_responsible_seq', 1, false);


--
-- Name: invoice_invoice_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.invoice_invoice_id_seq', 12, true);


--
-- Name: log_table_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.log_table_log_id_seq', 1904, true);


--
-- Name: rack_rack_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.rack_rack_id_seq', 126, true);


--
-- Name: rack_roomid_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.rack_roomid_seq', 1, false);


--
-- Name: room_room_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.room_room_id_seq', 26, true);


--
-- Name: room_warehouseid_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.room_warehouseid_seq', 1, false);


--
-- Name: shelf_rackid_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.shelf_rackid_seq', 1, false);


--
-- Name: shelf_shelf_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.shelf_shelf_id_seq', 625, true);


--
-- Name: warehouse_warehouse_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.warehouse_warehouse_id_seq', 9, true);


--
-- Name: counteragent counteragent_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.counteragent
    ADD CONSTRAINT counteragent_pkey PRIMARY KEY (counteragent_id);


--
-- Name: details details_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.details
    ADD CONSTRAINT details_pkey PRIMARY KEY (detail_id);


--
-- Name: employee employee_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.employee
    ADD CONSTRAINT employee_pkey PRIMARY KEY (employee_id);


--
-- Name: invoice_detail invoice_detail_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.invoice_detail
    ADD CONSTRAINT invoice_detail_unique UNIQUE (invoiceid, detailid);


--
-- Name: invoice_employee invoice_employee_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.invoice_employee
    ADD CONSTRAINT invoice_employee_unique UNIQUE (invoiceid, responsible);


--
-- Name: invoice invoice_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.invoice
    ADD CONSTRAINT invoice_pkey PRIMARY KEY (invoice_id);


--
-- Name: log_table log_table_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.log_table
    ADD CONSTRAINT log_table_pkey PRIMARY KEY (log_id);


--
-- Name: rack rack_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.rack
    ADD CONSTRAINT rack_pkey PRIMARY KEY (rack_id);


--
-- Name: room room_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.room
    ADD CONSTRAINT room_pkey PRIMARY KEY (room_id);


--
-- Name: shelf shelf_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.shelf
    ADD CONSTRAINT shelf_pkey PRIMARY KEY (shelf_id);


--
-- Name: warehouse unique_address; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouse
    ADD CONSTRAINT unique_address UNIQUE (address);


--
-- Name: warehouse warehouse_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouse
    ADD CONSTRAINT warehouse_pkey PRIMARY KEY (warehouse_id);


--
-- Name: counteragent counteragent_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER counteragent_changes AFTER INSERT OR DELETE OR UPDATE ON public.counteragent FOR EACH ROW EXECUTE FUNCTION public.log_counteragent_changes();


--
-- Name: rack delete_related_data; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER delete_related_data BEFORE DELETE ON public.rack FOR EACH ROW EXECUTE FUNCTION public.delete_related_data();


--
-- Name: room delete_related_data; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER delete_related_data BEFORE DELETE ON public.room FOR EACH ROW EXECUTE FUNCTION public.delete_related_data();


--
-- Name: shelf delete_related_data; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER delete_related_data BEFORE DELETE ON public.shelf FOR EACH ROW EXECUTE FUNCTION public.delete_related_data();


--
-- Name: warehouse delete_related_data; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER delete_related_data BEFORE DELETE ON public.warehouse FOR EACH ROW EXECUTE FUNCTION public.delete_related_data();


--
-- Name: details details_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER details_changes AFTER INSERT OR DELETE OR UPDATE ON public.details FOR EACH ROW EXECUTE FUNCTION public.log_details_changes();


--
-- Name: employee employee_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER employee_changes AFTER INSERT OR DELETE OR UPDATE ON public.employee FOR EACH ROW EXECUTE FUNCTION public.log_employee_changes();


--
-- Name: invoice invoice_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER invoice_changes AFTER INSERT OR DELETE OR UPDATE ON public.invoice FOR EACH ROW EXECUTE FUNCTION public.log_invoice_changes();


--
-- Name: invoice_detail invoice_detail_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER invoice_detail_changes AFTER INSERT OR DELETE OR UPDATE ON public.invoice_detail FOR EACH ROW EXECUTE FUNCTION public.log_invoice_detail_changes();


--
-- Name: invoice_details_view invoice_details_view_delete; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER invoice_details_view_delete INSTEAD OF DELETE ON public.invoice_details_view FOR EACH ROW EXECUTE FUNCTION public.delete_invoice_details_view();


--
-- Name: invoice_details_view invoice_details_view_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER invoice_details_view_insert INSTEAD OF INSERT ON public.invoice_details_view FOR EACH ROW EXECUTE FUNCTION public.insert_invoice_details_view();


--
-- Name: invoice_details_view invoice_details_view_update; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER invoice_details_view_update INSTEAD OF UPDATE ON public.invoice_details_view FOR EACH ROW EXECUTE FUNCTION public.update_invoice_details_view();


--
-- Name: invoice_employee invoice_employee_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER invoice_employee_changes AFTER INSERT OR DELETE OR UPDATE ON public.invoice_employee FOR EACH ROW EXECUTE FUNCTION public.log_invoice_employee_changes();


--
-- Name: rack rack_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER rack_changes AFTER INSERT OR DELETE OR UPDATE ON public.rack FOR EACH ROW EXECUTE FUNCTION public.log_rack_changes();


--
-- Name: room room_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER room_changes AFTER INSERT OR DELETE OR UPDATE ON public.room FOR EACH ROW EXECUTE FUNCTION public.log_room_changes();


--
-- Name: shelf shelf_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER shelf_changes AFTER INSERT OR DELETE OR UPDATE ON public.shelf FOR EACH ROW EXECUTE FUNCTION public.log_shelf_changes();


--
-- Name: invoice trg_delete_invoice_details; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_delete_invoice_details AFTER DELETE ON public.invoice FOR EACH ROW EXECUTE FUNCTION public.delete_invoice_details_view();


--
-- Name: warehouse trg_delete_related_data; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_delete_related_data BEFORE DELETE ON public.warehouse FOR EACH ROW EXECUTE FUNCTION public.delete_related_data();


--
-- Name: warehouse warehouse_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER warehouse_changes AFTER INSERT OR DELETE OR UPDATE ON public.warehouse FOR EACH ROW EXECUTE FUNCTION public.log_warehouse_changes();


--
-- Name: details details_shelfid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.details
    ADD CONSTRAINT details_shelfid_fkey FOREIGN KEY (shelfid) REFERENCES public.shelf(shelf_id);


--
-- Name: invoice invoice_counteragentid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.invoice
    ADD CONSTRAINT invoice_counteragentid_fkey FOREIGN KEY (counteragentid) REFERENCES public.counteragent(counteragent_id);


--
-- Name: invoice_detail invoice_detail_detailid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.invoice_detail
    ADD CONSTRAINT invoice_detail_detailid_fkey FOREIGN KEY (detailid) REFERENCES public.details(detail_id);


--
-- Name: invoice_detail invoice_detail_invoiceid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.invoice_detail
    ADD CONSTRAINT invoice_detail_invoiceid_fkey FOREIGN KEY (invoiceid) REFERENCES public.invoice(invoice_id);


--
-- Name: invoice_employee invoice_employee_granted_access_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.invoice_employee
    ADD CONSTRAINT invoice_employee_granted_access_fkey FOREIGN KEY (granted_access) REFERENCES public.employee(employee_id);


--
-- Name: invoice_employee invoice_employee_invoiceid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.invoice_employee
    ADD CONSTRAINT invoice_employee_invoiceid_fkey FOREIGN KEY (invoiceid) REFERENCES public.invoice(invoice_id);


--
-- Name: invoice_employee invoice_employee_responsible_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.invoice_employee
    ADD CONSTRAINT invoice_employee_responsible_fkey FOREIGN KEY (responsible) REFERENCES public.employee(employee_id);


--
-- Name: rack rack_roomid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.rack
    ADD CONSTRAINT rack_roomid_fkey FOREIGN KEY (roomid) REFERENCES public.room(room_id);


--
-- Name: room room_warehouseid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.room
    ADD CONSTRAINT room_warehouseid_fkey FOREIGN KEY (warehouseid) REFERENCES public.warehouse(warehouse_id);


--
-- Name: shelf shelf_rackid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.shelf
    ADD CONSTRAINT shelf_rackid_fkey FOREIGN KEY (rackid) REFERENCES public.rack(rack_id);


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA public TO warehouse_owner;


--
-- Name: FUNCTION convert_text_to_boolean(text_value text, field_type text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.convert_text_to_boolean(text_value text, field_type text) TO warehouse_owner;


--
-- Name: FUNCTION delete_invoice_details_view(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.delete_invoice_details_view() TO warehouse_owner;


--
-- Name: FUNCTION delete_related_data(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.delete_related_data() TO warehouse_owner;


--
-- Name: FUNCTION delete_warehouse_details(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.delete_warehouse_details() TO warehouse_owner;


--
-- Name: FUNCTION get_employee_id(p_last_name character varying, p_first_name character varying, p_patronymic character varying); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.get_employee_id(p_last_name character varying, p_first_name character varying, p_patronymic character varying) TO warehouse_owner;
GRANT ALL ON FUNCTION public.get_employee_id(p_last_name character varying, p_first_name character varying, p_patronymic character varying) TO warehouse_manager;


--
-- Name: FUNCTION insert_into_warehouse_details(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.insert_into_warehouse_details() TO warehouse_owner;


--
-- Name: FUNCTION insert_invoice_details_view(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.insert_invoice_details_view() TO warehouse_owner;
GRANT ALL ON FUNCTION public.insert_invoice_details_view() TO warehouse_manager;


--
-- Name: FUNCTION log_counteragent_changes(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.log_counteragent_changes() TO warehouse_owner;


--
-- Name: FUNCTION log_details_changes(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.log_details_changes() TO warehouse_owner;


--
-- Name: FUNCTION log_employee_changes(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.log_employee_changes() TO warehouse_owner;


--
-- Name: FUNCTION log_invoice_changes(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.log_invoice_changes() TO warehouse_owner;


--
-- Name: FUNCTION log_invoice_detail_changes(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.log_invoice_detail_changes() TO warehouse_owner;


--
-- Name: FUNCTION log_invoice_employee_changes(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.log_invoice_employee_changes() TO warehouse_owner;


--
-- Name: FUNCTION log_rack_changes(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.log_rack_changes() TO warehouse_owner;


--
-- Name: FUNCTION log_room_changes(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.log_room_changes() TO warehouse_owner;


--
-- Name: FUNCTION log_shelf_changes(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.log_shelf_changes() TO warehouse_owner;


--
-- Name: FUNCTION log_warehouse_changes(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.log_warehouse_changes() TO warehouse_owner;


--
-- Name: FUNCTION update_invoice_details_view(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.update_invoice_details_view() TO warehouse_owner;


--
-- Name: FUNCTION update_invoice_status(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.update_invoice_status() TO warehouse_owner;


--
-- Name: FUNCTION update_warehouse_details_view(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.update_warehouse_details_view() TO warehouse_owner;


--
-- Name: TABLE counteragent; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.counteragent TO warehouse_owner;
GRANT SELECT ON TABLE public.counteragent TO warehouse_manager;


--
-- Name: SEQUENCE counteragent_counteragent_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.counteragent_counteragent_id_seq TO warehouse_owner;


--
-- Name: TABLE details; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,DELETE ON TABLE public.details TO warehouse_owner;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.details TO warehouse_clerk;
GRANT SELECT ON TABLE public.details TO warehouse_manager;


--
-- Name: SEQUENCE details_detail_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.details_detail_id_seq TO warehouse_clerk;
GRANT SELECT,USAGE ON SEQUENCE public.details_detail_id_seq TO warehouse_owner;


--
-- Name: SEQUENCE details_shelfid_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.details_shelfid_seq TO warehouse_owner;


--
-- Name: TABLE employee; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.employee TO warehouse_owner;


--
-- Name: SEQUENCE employee_employee_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.employee_employee_id_seq TO warehouse_owner;
GRANT SELECT,USAGE ON SEQUENCE public.employee_employee_id_seq TO warehouse_manager;


--
-- Name: TABLE invoice; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.invoice TO warehouse_owner;
GRANT SELECT,UPDATE ON TABLE public.invoice TO warehouse_clerk;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.invoice TO warehouse_manager;


--
-- Name: SEQUENCE invoice_counteragentid_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.invoice_counteragentid_seq TO warehouse_owner;


--
-- Name: TABLE invoice_detail; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.invoice_detail TO warehouse_owner;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.invoice_detail TO warehouse_manager;
GRANT SELECT ON TABLE public.invoice_detail TO warehouse_clerk;


--
-- Name: SEQUENCE invoice_detail_detailid_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.invoice_detail_detailid_seq TO warehouse_owner;


--
-- Name: SEQUENCE invoice_detail_invoiceid_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.invoice_detail_invoiceid_seq TO warehouse_manager;
GRANT SELECT,USAGE ON SEQUENCE public.invoice_detail_invoiceid_seq TO warehouse_owner;


--
-- Name: TABLE invoice_employee; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.invoice_employee TO warehouse_owner;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.invoice_employee TO warehouse_manager;
GRANT SELECT ON TABLE public.invoice_employee TO warehouse_clerk;


--
-- Name: TABLE invoice_details_view; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.invoice_details_view TO warehouse_owner;
GRANT SELECT,UPDATE ON TABLE public.invoice_details_view TO warehouse_clerk;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.invoice_details_view TO warehouse_manager;


--
-- Name: SEQUENCE invoice_employee_granted_access_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.invoice_employee_granted_access_seq TO warehouse_owner;


--
-- Name: SEQUENCE invoice_employee_invoiceid_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.invoice_employee_invoiceid_seq TO warehouse_owner;


--
-- Name: SEQUENCE invoice_employee_responsible_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.invoice_employee_responsible_seq TO warehouse_owner;


--
-- Name: SEQUENCE invoice_invoice_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.invoice_invoice_id_seq TO warehouse_manager;
GRANT SELECT,USAGE ON SEQUENCE public.invoice_invoice_id_seq TO warehouse_owner;


--
-- Name: TABLE log_table; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE public.log_table TO warehouse_owner;
GRANT SELECT,INSERT ON TABLE public.log_table TO warehouse_clerk;
GRANT SELECT,INSERT ON TABLE public.log_table TO warehouse_manager;


--
-- Name: SEQUENCE log_table_log_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.log_table_log_id_seq TO warehouse_clerk;
GRANT SELECT,USAGE ON SEQUENCE public.log_table_log_id_seq TO warehouse_manager;
GRANT SELECT,USAGE ON SEQUENCE public.log_table_log_id_seq TO warehouse_owner;


--
-- Name: TABLE rack; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.rack TO warehouse_owner;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.rack TO warehouse_clerk;


--
-- Name: SEQUENCE rack_rack_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.rack_rack_id_seq TO warehouse_owner;
GRANT SELECT,USAGE ON SEQUENCE public.rack_rack_id_seq TO warehouse_clerk;


--
-- Name: SEQUENCE rack_roomid_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.rack_roomid_seq TO warehouse_owner;


--
-- Name: TABLE room; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.room TO warehouse_owner;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.room TO warehouse_clerk;


--
-- Name: SEQUENCE room_room_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.room_room_id_seq TO warehouse_owner;
GRANT SELECT,USAGE ON SEQUENCE public.room_room_id_seq TO warehouse_clerk;


--
-- Name: SEQUENCE room_warehouseid_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.room_warehouseid_seq TO warehouse_owner;


--
-- Name: TABLE shelf; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.shelf TO warehouse_owner;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.shelf TO warehouse_clerk;


--
-- Name: SEQUENCE shelf_rackid_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.shelf_rackid_seq TO warehouse_owner;


--
-- Name: SEQUENCE shelf_shelf_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.shelf_shelf_id_seq TO warehouse_owner;
GRANT SELECT,USAGE ON SEQUENCE public.shelf_shelf_id_seq TO warehouse_clerk;


--
-- Name: TABLE warehouse; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.warehouse TO warehouse_owner;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.warehouse TO warehouse_clerk;


--
-- Name: TABLE warehouse_details_view; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.warehouse_details_view TO warehouse_owner;
GRANT SELECT,INSERT,UPDATE ON TABLE public.warehouse_details_view TO warehouse_clerk;
GRANT SELECT ON TABLE public.warehouse_details_view TO warehouse_manager;


--
-- Name: SEQUENCE warehouse_warehouse_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE public.warehouse_warehouse_id_seq TO warehouse_owner;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO warehouse_owner;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT ON TABLES TO warehouse_owner;


--
-- PostgreSQL database dump complete
--

