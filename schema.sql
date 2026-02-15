--
-- PostgreSQL database dump
--

\restrict Ra4bf5XeBEPSnqi9GSN9nKP76c9NBGQblCPjCFxiLgxHrLzTUdOsE9drcXzZFMZ

-- Dumped from database version 18.1
-- Dumped by pg_dump version 18.1

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
-- Name: archive_client_on_deactivation(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.archive_client_on_deactivation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Архивация только при переходе в статус 'inactive'
    IF NEW.status = 'inactive' AND OLD.status != 'inactive' THEN
        INSERT INTO clients_archive (
            client_id, full_name, email, phone, registration_date,
            deactivation_reason, total_orders, total_spent
        )
        SELECT 
            OLD.id,
            OLD.full_name,
            OLD.email,
            OLD.phone,
            OLD.registration_date,
            'Деактивация через систему управления',
            COUNT(o.id),
            COALESCE(SUM(o.order_total + o.delivery_cost), 0)
        FROM clients c
        LEFT JOIN orders o ON o.client_id = c.id
        WHERE c.id = OLD.id
        GROUP BY c.id;
    END IF;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.archive_client_on_deactivation() OWNER TO postgres;

--
-- Name: assign_free_courier(integer, integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.assign_free_courier(IN p_order_id integer, IN p_delivery_address_id integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_courier_id INTEGER;
    v_active_orders INTEGER;
BEGIN
    -- Поиск курьера с минимальной загруженностью (активные заказы со статусом 'в пути')
    SELECT u.id, COUNT(o.id) AS active_count
    INTO v_courier_id, v_active_orders
    FROM users u
    LEFT JOIN orders o ON o.courier_id = u.id 
        AND o.status_id IN (SELECT id FROM order_statuses WHERE code IN ('assigned', 'dispatched'))
    WHERE u.role_id = (SELECT id FROM roles WHERE name = 'courier')
        AND u.status = 'works'
    GROUP BY u.id
    ORDER BY active_count ASC, u.hire_date ASC  -- предпочитаем менее загруженных и более опытных
    LIMIT 1;
    
    IF v_courier_id IS NOT NULL THEN
        -- Назначение курьера и фиксация времени
        UPDATE orders
        SET courier_id = v_courier_id,
            courier_assigned_at = NOW(),
            status_id = (SELECT id FROM order_statuses WHERE code = 'assigned')
        WHERE id = p_order_id;
        
        RAISE NOTICE 'Курьер % назначен на заказ % (активных заказов: %)', v_courier_id, p_order_id, v_active_orders;
    ELSE
        RAISE WARNING 'Свободные курьеры не найдены для заказа %', p_order_id;
    END IF;
END;
$$;


ALTER PROCEDURE public.assign_free_courier(IN p_order_id integer, IN p_delivery_address_id integer) OWNER TO postgres;

--
-- Name: calculate_client_rating(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.calculate_client_rating(p_client_id integer) RETURNS numeric
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_total_orders INTEGER;
    v_avg_rating NUMERIC(3,2);
    v_recent_orders INTEGER;
    v_final_rating NUMERIC(3,2) := 0.00;
BEGIN
    -- Общее количество заказов за последний год
    SELECT COUNT(*) INTO v_total_orders
    FROM orders
    WHERE client_id = p_client_id
        AND created_at >= NOW() - INTERVAL '1 year';
    
    -- Средний рейтинг по отзывам
    SELECT COALESCE(AVG(rating), 5.0) INTO v_avg_rating
    FROM reviews r
    JOIN orders o ON r.order_id = o.id
    WHERE o.client_id = p_client_id;
    
    -- Количество заказов за последний месяц
    SELECT COUNT(*) INTO v_recent_orders
    FROM orders
    WHERE client_id = p_client_id
        AND created_at >= NOW() - INTERVAL '1 month';
    
    -- Расчет итогового рейтинга (макс. 10.00)
    v_final_rating := LEAST(
        (v_total_orders * 0.3) +        -- 30% за лояльность
        (v_avg_rating * 1.2) +          -- 120% за качество отзывов
        (v_recent_orders * 0.5),        -- 50% за активность
        10.00
    );
    
    RETURN ROUND(v_final_rating, 2);
END;
$$;


ALTER FUNCTION public.calculate_client_rating(p_client_id integer) OWNER TO postgres;

--
-- Name: calculate_delivery_cost(integer, numeric, numeric); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.calculate_delivery_cost(IN p_order_id integer, IN p_distance_km numeric, IN p_total_weight_kg numeric)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_base_cost NUMERIC := 150.00;  -- базовая стоимость доставки
    v_distance_coeff NUMERIC := 10.00;  -- коэффициент за км
    v_weight_coeff NUMERIC := 5.00;  -- коэффициент за кг свыше 5 кг
    v_extra_weight NUMERIC;
    v_final_cost NUMERIC;
BEGIN
    -- Расчет дополнительной стоимости за расстояние
    v_final_cost := v_base_cost + (p_distance_km * v_distance_coeff);
    
    -- Добавление стоимости за превышение веса (свыше 5 кг)
    v_extra_weight := GREATEST(p_total_weight_kg - 5, 0);
    v_final_cost := v_final_cost + (v_extra_weight * v_weight_coeff);
    
    -- Обновление стоимости в заказе
    UPDATE orders 
    SET delivery_cost = v_final_cost
    WHERE id = p_order_id;
    
    RAISE NOTICE 'Стоимость доставки для заказа % рассчитана: % руб.', p_order_id, v_final_cost;
END;
$$;


ALTER PROCEDURE public.calculate_delivery_cost(IN p_order_id integer, IN p_distance_km numeric, IN p_total_weight_kg numeric) OWNER TO postgres;

--
-- Name: generate_courier_report(date, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.generate_courier_report(p_start_date date, p_end_date date) RETURNS TABLE(courier_id integer, courier_name character varying, total_deliveries integer, avg_delivery_time interval, total_earnings numeric, success_rate numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        u.id AS courier_id,
        u.full_name AS courier_name,
        COUNT(o.id) AS total_deliveries,
        AVG(o.delivered_at - o.courier_assigned_at) AS avg_delivery_time,
        SUM(o.delivery_cost) AS total_earnings,
        ROUND(
            COUNT(CASE WHEN o.delivered_at <= o.created_at + INTERVAL '2 hours' THEN 1 END)::NUMERIC 
            / NULLIF(COUNT(o.id), 0) * 100, 2
        ) AS success_rate  -- % заказов доставленных в течение 2 часов
    FROM users u
    INNER JOIN orders o ON o.courier_id = u.id
    WHERE u.role_id = (SELECT id FROM roles WHERE name = 'courier')
        AND o.delivered_at BETWEEN p_start_date AND p_end_date
        AND o.status_id = (SELECT id FROM order_statuses WHERE code = 'delivered')
    GROUP BY u.id, u.full_name
    ORDER BY total_deliveries DESC;
END;
$$;


ALTER FUNCTION public.generate_courier_report(p_start_date date, p_end_date date) OWNER TO postgres;

--
-- Name: prevent_courier_deletion_with_active_orders(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prevent_courier_deletion_with_active_orders() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_is_courier BOOLEAN;
    v_active_orders_count INTEGER;
    v_courier_role_id INTEGER;
BEGIN
    -- Получение ID роли 'courier' один раз
    SELECT id INTO v_courier_role_id FROM roles WHERE name = 'courier';
    
    -- Проверка: является ли удаляемый пользователь курьером
    IF OLD.role_id != v_courier_role_id THEN
        RETURN OLD;  -- Не курьер — разрешаем удаление без проверок
    END IF;
    
    -- Проверка наличия активных заказов (не delivered и не cancelled)
    SELECT COUNT(*) INTO v_active_orders_count
    FROM orders
    WHERE courier_id = OLD.id
        AND status_id NOT IN (
            SELECT id FROM order_statuses WHERE code IN ('delivered', 'cancelled')
        );
    
    IF v_active_orders_count > 0 THEN
        RAISE EXCEPTION 'Невозможно удалить курьера: обнаружено % активных заказов. Сначала переназначьте заказы.', v_active_orders_count;
    END IF;
    
    RETURN OLD;
END;
$$;


ALTER FUNCTION public.prevent_courier_deletion_with_active_orders() OWNER TO postgres;

--
-- Name: set_order_timestamps(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_order_timestamps() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_new_status_code VARCHAR(20);
BEGIN
    -- Получение нового статуса
    SELECT code INTO v_new_status_code FROM order_statuses WHERE id = NEW.status_id;
    
    -- Установка временных меток при первом переходе в статус
    IF v_new_status_code = 'confirmed' AND OLD.confirmed_at IS NULL THEN
        NEW.confirmed_at := NOW();
    ELSIF v_new_status_code = 'assigned' AND OLD.courier_assigned_at IS NULL THEN
        NEW.courier_assigned_at := NOW();
    ELSIF v_new_status_code = 'dispatched' AND OLD.dispatched_at IS NULL THEN
        NEW.dispatched_at := NOW();
    ELSIF v_new_status_code = 'delivered' AND OLD.delivered_at IS NULL THEN
        NEW.delivered_at := NOW();
    END IF;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.set_order_timestamps() OWNER TO postgres;

--
-- Name: update_order_status(integer, character varying); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.update_order_status(IN p_order_id integer, IN p_new_status_code character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_current_status_code VARCHAR(20);
    v_allowed_transition BOOLEAN;
BEGIN
    -- Получение текущего статуса
    SELECT os.code INTO v_current_status_code
    FROM orders o
    JOIN order_statuses os ON o.status_id = os.id
    WHERE o.id = p_order_id;
    
    -- Проверка допустимости перехода (бизнес-правило последовательности)
    SELECT CASE 
        WHEN v_current_status_code = 'created' AND p_new_status_code IN ('confirmed', 'cancelled') THEN TRUE
        WHEN v_current_status_code = 'confirmed' AND p_new_status_code = 'assigned' THEN TRUE
        WHEN v_current_status_code = 'assigned' AND p_new_status_code = 'dispatched' THEN TRUE
        WHEN v_current_status_code = 'dispatched' AND p_new_status_code = 'delivered' THEN TRUE
        WHEN p_new_status_code = 'cancelled' THEN TRUE  -- отмена возможна из любого статуса
        ELSE FALSE
    END INTO v_allowed_transition;
    
    IF NOT v_allowed_transition THEN
        RAISE EXCEPTION 'Недопустимый переход статуса: % → %', v_current_status_code, p_new_status_code;
    END IF;
    
    -- Обновление статуса и временных меток
    UPDATE orders
    SET 
        status_id = (SELECT id FROM order_statuses WHERE code = p_new_status_code),
        confirmed_at = CASE WHEN p_new_status_code = 'confirmed' AND confirmed_at IS NULL THEN NOW() ELSE confirmed_at END,
        dispatched_at = CASE WHEN p_new_status_code = 'dispatched' AND dispatched_at IS NULL THEN NOW() ELSE dispatched_at END,
        delivered_at = CASE WHEN p_new_status_code = 'delivered' AND delivered_at IS NULL THEN NOW() ELSE delivered_at END
    WHERE id = p_order_id;
    
    RAISE NOTICE 'Статус заказа % изменен: % → %', p_order_id, v_current_status_code, p_new_status_code;
END;
$$;


ALTER PROCEDURE public.update_order_status(IN p_order_id integer, IN p_new_status_code character varying) OWNER TO postgres;

--
-- Name: update_order_total(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_order_total() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Пересчет общей стоимости заказа на основе товаров
    UPDATE orders o
    SET order_total = COALESCE((
        SELECT SUM(oi.quantity * oi.price_at_order)
        FROM order_items oi
        WHERE oi.order_id = o.id
    ), 0)
    WHERE o.id = NEW.order_id;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_order_total() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: addresses; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.addresses (
    id bigint NOT NULL,
    street character varying(255) NOT NULL,
    house_number character varying(20) NOT NULL,
    apartment_number character varying(10),
    entrance character varying(10),
    floor integer,
    door_code character varying(10),
    latitude numeric(10,7),
    longitude numeric(10,7)
);


ALTER TABLE public.addresses OWNER TO postgres;

--
-- Name: addresses_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.addresses ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.addresses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_group; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_group (
    id integer NOT NULL,
    name character varying(150) NOT NULL
);


ALTER TABLE public.auth_group OWNER TO postgres;

--
-- Name: auth_group_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.auth_group ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_group_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_group_permissions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_group_permissions (
    id bigint NOT NULL,
    group_id integer NOT NULL,
    permission_id integer NOT NULL
);


ALTER TABLE public.auth_group_permissions OWNER TO postgres;

--
-- Name: auth_group_permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.auth_group_permissions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_group_permissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_permission; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_permission (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    content_type_id integer NOT NULL,
    codename character varying(100) NOT NULL
);


ALTER TABLE public.auth_permission OWNER TO postgres;

--
-- Name: auth_permission_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.auth_permission ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_permission_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_user; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_user (
    id integer NOT NULL,
    password character varying(128) NOT NULL,
    last_login timestamp with time zone,
    is_superuser boolean NOT NULL,
    username character varying(150) NOT NULL,
    first_name character varying(150) NOT NULL,
    last_name character varying(150) NOT NULL,
    email character varying(254) NOT NULL,
    is_staff boolean NOT NULL,
    is_active boolean NOT NULL,
    date_joined timestamp with time zone NOT NULL
);


ALTER TABLE public.auth_user OWNER TO postgres;

--
-- Name: auth_user_groups; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_user_groups (
    id bigint NOT NULL,
    user_id integer NOT NULL,
    group_id integer NOT NULL
);


ALTER TABLE public.auth_user_groups OWNER TO postgres;

--
-- Name: auth_user_groups_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.auth_user_groups ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_user_groups_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_user_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.auth_user ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_user_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_user_user_permissions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_user_user_permissions (
    id bigint NOT NULL,
    user_id integer NOT NULL,
    permission_id integer NOT NULL
);


ALTER TABLE public.auth_user_user_permissions OWNER TO postgres;

--
-- Name: auth_user_user_permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.auth_user_user_permissions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_user_user_permissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: clients; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.clients (
    id bigint NOT NULL,
    email character varying(254) NOT NULL,
    phone character varying(20) NOT NULL,
    full_name character varying(255) NOT NULL,
    registration_date timestamp with time zone NOT NULL,
    status character varying(20) NOT NULL
);


ALTER TABLE public.clients OWNER TO postgres;

--
-- Name: clients_archive; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.clients_archive (
    archive_id integer NOT NULL,
    client_id integer NOT NULL,
    full_name character varying(255),
    email character varying(255),
    phone character varying(20),
    registration_date timestamp without time zone,
    deactivation_date timestamp without time zone DEFAULT now(),
    deactivation_reason text,
    total_orders integer,
    total_spent numeric(12,2)
);


ALTER TABLE public.clients_archive OWNER TO postgres;

--
-- Name: clients_archive_archive_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.clients_archive_archive_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.clients_archive_archive_id_seq OWNER TO postgres;

--
-- Name: clients_archive_archive_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.clients_archive_archive_id_seq OWNED BY public.clients_archive.archive_id;


--
-- Name: clients_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.clients ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.clients_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: django_admin_log; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.django_admin_log (
    id integer NOT NULL,
    action_time timestamp with time zone NOT NULL,
    object_id text,
    object_repr character varying(200) NOT NULL,
    action_flag smallint NOT NULL,
    change_message text NOT NULL,
    content_type_id integer,
    user_id integer NOT NULL,
    CONSTRAINT django_admin_log_action_flag_check CHECK ((action_flag >= 0))
);


ALTER TABLE public.django_admin_log OWNER TO postgres;

--
-- Name: django_admin_log_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.django_admin_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.django_admin_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: django_content_type; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.django_content_type (
    id integer NOT NULL,
    app_label character varying(100) NOT NULL,
    model character varying(100) NOT NULL
);


ALTER TABLE public.django_content_type OWNER TO postgres;

--
-- Name: django_content_type_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.django_content_type ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.django_content_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: django_migrations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.django_migrations (
    id bigint NOT NULL,
    app character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    applied timestamp with time zone NOT NULL
);


ALTER TABLE public.django_migrations OWNER TO postgres;

--
-- Name: django_migrations_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.django_migrations ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.django_migrations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: django_session; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.django_session (
    session_key character varying(40) NOT NULL,
    session_data text NOT NULL,
    expire_date timestamp with time zone NOT NULL
);


ALTER TABLE public.django_session OWNER TO postgres;

--
-- Name: order_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.order_items (
    id bigint NOT NULL,
    quantity smallint NOT NULL,
    price_at_order numeric(10,2) NOT NULL,
    order_id bigint NOT NULL,
    product_id bigint NOT NULL
);


ALTER TABLE public.order_items OWNER TO postgres;

--
-- Name: order_items_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.order_items ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.order_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: order_statuses; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.order_statuses (
    id bigint NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(50) NOT NULL,
    sort_order smallint NOT NULL
);


ALTER TABLE public.order_statuses OWNER TO postgres;

--
-- Name: order_statuses_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.order_statuses ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.order_statuses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: orders; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.orders (
    id bigint NOT NULL,
    delivery_cost numeric(10,2) NOT NULL,
    order_total numeric(10,2) NOT NULL,
    created_at timestamp with time zone NOT NULL,
    confirmed_at timestamp with time zone,
    courier_assigned_at timestamp with time zone,
    dispatched_at timestamp with time zone,
    delivered_at timestamp with time zone,
    comment text,
    client_id bigint NOT NULL,
    delivery_address_id bigint NOT NULL,
    pickup_address_id bigint,
    status_id bigint NOT NULL,
    payment_method_id bigint NOT NULL,
    courier_id bigint
);


ALTER TABLE public.orders OWNER TO postgres;

--
-- Name: orders_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.orders ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.orders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: payment_methods; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.payment_methods (
    id bigint NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(50) NOT NULL,
    fee_percent numeric(5,2) NOT NULL
);


ALTER TABLE public.payment_methods OWNER TO postgres;

--
-- Name: payment_methods_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.payment_methods ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.payment_methods_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: payments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.payments (
    id bigint NOT NULL,
    amount numeric(10,2) NOT NULL,
    status character varying(20) NOT NULL,
    transaction_number character varying(100),
    paid_at timestamp with time zone NOT NULL,
    order_id bigint NOT NULL,
    payment_method_id bigint NOT NULL
);


ALTER TABLE public.payments OWNER TO postgres;

--
-- Name: payments_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.payments ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.payments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: products; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.products (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    price numeric(10,2) NOT NULL,
    weight_kg numeric(5,2) NOT NULL,
    dimensions_cm character varying(50)
);


ALTER TABLE public.products OWNER TO postgres;

--
-- Name: products_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.products ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: reviews; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.reviews (
    id bigint NOT NULL,
    rating smallint NOT NULL,
    text text,
    created_at timestamp with time zone NOT NULL,
    order_id bigint NOT NULL
);


ALTER TABLE public.reviews OWNER TO postgres;

--
-- Name: reviews_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.reviews ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.reviews_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: roles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.roles (
    id bigint NOT NULL,
    name character varying(50) NOT NULL,
    description text
);


ALTER TABLE public.roles OWNER TO postgres;

--
-- Name: roles_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.roles ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    login character varying(50) NOT NULL,
    password_hash character varying(255) NOT NULL,
    full_name character varying(255) NOT NULL,
    phone character varying(20) NOT NULL,
    status character varying(20) NOT NULL,
    hire_date date NOT NULL,
    role_id bigint NOT NULL
);


ALTER TABLE public.users OWNER TO postgres;

--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.users ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: clients_archive archive_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.clients_archive ALTER COLUMN archive_id SET DEFAULT nextval('public.clients_archive_archive_id_seq'::regclass);


--
-- Name: addresses addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.addresses
    ADD CONSTRAINT addresses_pkey PRIMARY KEY (id);


--
-- Name: auth_group auth_group_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_group
    ADD CONSTRAINT auth_group_name_key UNIQUE (name);


--
-- Name: auth_group_permissions auth_group_permissions_group_id_permission_id_0cd325b0_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissions_group_id_permission_id_0cd325b0_uniq UNIQUE (group_id, permission_id);


--
-- Name: auth_group_permissions auth_group_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissions_pkey PRIMARY KEY (id);


--
-- Name: auth_group auth_group_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_group
    ADD CONSTRAINT auth_group_pkey PRIMARY KEY (id);


--
-- Name: auth_permission auth_permission_content_type_id_codename_01ab375a_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_permission
    ADD CONSTRAINT auth_permission_content_type_id_codename_01ab375a_uniq UNIQUE (content_type_id, codename);


--
-- Name: auth_permission auth_permission_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_permission
    ADD CONSTRAINT auth_permission_pkey PRIMARY KEY (id);


--
-- Name: auth_user_groups auth_user_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_groups
    ADD CONSTRAINT auth_user_groups_pkey PRIMARY KEY (id);


--
-- Name: auth_user_groups auth_user_groups_user_id_group_id_94350c0c_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_groups
    ADD CONSTRAINT auth_user_groups_user_id_group_id_94350c0c_uniq UNIQUE (user_id, group_id);


--
-- Name: auth_user auth_user_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user
    ADD CONSTRAINT auth_user_pkey PRIMARY KEY (id);


--
-- Name: auth_user_user_permissions auth_user_user_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_user_permissions
    ADD CONSTRAINT auth_user_user_permissions_pkey PRIMARY KEY (id);


--
-- Name: auth_user_user_permissions auth_user_user_permissions_user_id_permission_id_14a6b632_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_user_permissions
    ADD CONSTRAINT auth_user_user_permissions_user_id_permission_id_14a6b632_uniq UNIQUE (user_id, permission_id);


--
-- Name: auth_user auth_user_username_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user
    ADD CONSTRAINT auth_user_username_key UNIQUE (username);


--
-- Name: clients_archive clients_archive_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.clients_archive
    ADD CONSTRAINT clients_archive_pkey PRIMARY KEY (archive_id);


--
-- Name: clients clients_email_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.clients
    ADD CONSTRAINT clients_email_key UNIQUE (email);


--
-- Name: clients clients_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.clients
    ADD CONSTRAINT clients_pkey PRIMARY KEY (id);


--
-- Name: django_admin_log django_admin_log_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_admin_log
    ADD CONSTRAINT django_admin_log_pkey PRIMARY KEY (id);


--
-- Name: django_content_type django_content_type_app_label_model_76bd3d3b_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_content_type
    ADD CONSTRAINT django_content_type_app_label_model_76bd3d3b_uniq UNIQUE (app_label, model);


--
-- Name: django_content_type django_content_type_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_content_type
    ADD CONSTRAINT django_content_type_pkey PRIMARY KEY (id);


--
-- Name: django_migrations django_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_migrations
    ADD CONSTRAINT django_migrations_pkey PRIMARY KEY (id);


--
-- Name: django_session django_session_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_session
    ADD CONSTRAINT django_session_pkey PRIMARY KEY (session_key);


--
-- Name: order_items order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_pkey PRIMARY KEY (id);


--
-- Name: order_statuses order_statuses_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_statuses
    ADD CONSTRAINT order_statuses_code_key UNIQUE (code);


--
-- Name: order_statuses order_statuses_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_statuses
    ADD CONSTRAINT order_statuses_pkey PRIMARY KEY (id);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);


--
-- Name: payment_methods payment_methods_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_methods
    ADD CONSTRAINT payment_methods_code_key UNIQUE (code);


--
-- Name: payment_methods payment_methods_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_methods
    ADD CONSTRAINT payment_methods_pkey PRIMARY KEY (id);


--
-- Name: payments payments_order_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_order_id_key UNIQUE (order_id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: reviews reviews_order_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_order_id_key UNIQUE (order_id);


--
-- Name: reviews reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_pkey PRIMARY KEY (id);


--
-- Name: roles roles_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_name_key UNIQUE (name);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: users users_login_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_login_key UNIQUE (login);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: auth_group_name_a6ea08ec_like; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_group_name_a6ea08ec_like ON public.auth_group USING btree (name varchar_pattern_ops);


--
-- Name: auth_group_permissions_group_id_b120cbf9; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_group_permissions_group_id_b120cbf9 ON public.auth_group_permissions USING btree (group_id);


--
-- Name: auth_group_permissions_permission_id_84c5c92e; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_group_permissions_permission_id_84c5c92e ON public.auth_group_permissions USING btree (permission_id);


--
-- Name: auth_permission_content_type_id_2f476e4b; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_permission_content_type_id_2f476e4b ON public.auth_permission USING btree (content_type_id);


--
-- Name: auth_user_groups_group_id_97559544; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_user_groups_group_id_97559544 ON public.auth_user_groups USING btree (group_id);


--
-- Name: auth_user_groups_user_id_6a12ed8b; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_user_groups_user_id_6a12ed8b ON public.auth_user_groups USING btree (user_id);


--
-- Name: auth_user_user_permissions_permission_id_1fbb5f2c; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_user_user_permissions_permission_id_1fbb5f2c ON public.auth_user_user_permissions USING btree (permission_id);


--
-- Name: auth_user_user_permissions_user_id_a95ead1b; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_user_user_permissions_user_id_a95ead1b ON public.auth_user_user_permissions USING btree (user_id);


--
-- Name: auth_user_username_6821ab7c_like; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_user_username_6821ab7c_like ON public.auth_user USING btree (username varchar_pattern_ops);


--
-- Name: clients_email_a0f0165c_like; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX clients_email_a0f0165c_like ON public.clients USING btree (email varchar_pattern_ops);


--
-- Name: django_admin_log_content_type_id_c4bce8eb; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX django_admin_log_content_type_id_c4bce8eb ON public.django_admin_log USING btree (content_type_id);


--
-- Name: django_admin_log_user_id_c564eba6; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX django_admin_log_user_id_c564eba6 ON public.django_admin_log USING btree (user_id);


--
-- Name: django_session_expire_date_a5c62663; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX django_session_expire_date_a5c62663 ON public.django_session USING btree (expire_date);


--
-- Name: django_session_session_key_c0390e0f_like; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX django_session_session_key_c0390e0f_like ON public.django_session USING btree (session_key varchar_pattern_ops);


--
-- Name: order_items_order_id_412ad78b; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX order_items_order_id_412ad78b ON public.order_items USING btree (order_id);


--
-- Name: order_items_product_id_dd557d5a; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX order_items_product_id_dd557d5a ON public.order_items USING btree (product_id);


--
-- Name: order_statuses_code_c0f956d1_like; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX order_statuses_code_c0f956d1_like ON public.order_statuses USING btree (code varchar_pattern_ops);


--
-- Name: orders_client_id_67f0b211; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX orders_client_id_67f0b211 ON public.orders USING btree (client_id);


--
-- Name: orders_courier_id_1aa0ca80; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX orders_courier_id_1aa0ca80 ON public.orders USING btree (courier_id);


--
-- Name: orders_delivery_address_id_e5955160; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX orders_delivery_address_id_e5955160 ON public.orders USING btree (delivery_address_id);


--
-- Name: orders_payment_method_id_dfb69856; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX orders_payment_method_id_dfb69856 ON public.orders USING btree (payment_method_id);


--
-- Name: orders_pickup_address_id_a8fad629; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX orders_pickup_address_id_a8fad629 ON public.orders USING btree (pickup_address_id);


--
-- Name: orders_status_id_e763064e; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX orders_status_id_e763064e ON public.orders USING btree (status_id);


--
-- Name: payment_methods_code_c05992bf_like; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX payment_methods_code_c05992bf_like ON public.payment_methods USING btree (code varchar_pattern_ops);


--
-- Name: payments_payment_method_id_83b27e37; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX payments_payment_method_id_83b27e37 ON public.payments USING btree (payment_method_id);


--
-- Name: roles_name_51259447_like; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX roles_name_51259447_like ON public.roles USING btree (name varchar_pattern_ops);


--
-- Name: users_login_3b007138_like; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX users_login_3b007138_like ON public.users USING btree (login varchar_pattern_ops);


--
-- Name: users_role_id_1900a745; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX users_role_id_1900a745 ON public.users USING btree (role_id);


--
-- Name: clients trg_archive_client_on_deactivation; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_archive_client_on_deactivation AFTER UPDATE OF status ON public.clients FOR EACH ROW WHEN (((new.status)::text = 'inactive'::text)) EXECUTE FUNCTION public.archive_client_on_deactivation();


--
-- Name: users trg_prevent_courier_deletion; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_prevent_courier_deletion BEFORE DELETE ON public.users FOR EACH ROW EXECUTE FUNCTION public.prevent_courier_deletion_with_active_orders();


--
-- Name: orders trg_set_order_timestamps; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_set_order_timestamps BEFORE UPDATE OF status_id ON public.orders FOR EACH ROW EXECUTE FUNCTION public.set_order_timestamps();


--
-- Name: order_items trg_update_order_total_after_change; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_order_total_after_change AFTER INSERT OR DELETE OR UPDATE ON public.order_items FOR EACH ROW EXECUTE FUNCTION public.update_order_total();


--
-- Name: auth_group_permissions auth_group_permissio_permission_id_84c5c92e_fk_auth_perm; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissio_permission_id_84c5c92e_fk_auth_perm FOREIGN KEY (permission_id) REFERENCES public.auth_permission(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_group_permissions auth_group_permissions_group_id_b120cbf9_fk_auth_group_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissions_group_id_b120cbf9_fk_auth_group_id FOREIGN KEY (group_id) REFERENCES public.auth_group(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_permission auth_permission_content_type_id_2f476e4b_fk_django_co; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_permission
    ADD CONSTRAINT auth_permission_content_type_id_2f476e4b_fk_django_co FOREIGN KEY (content_type_id) REFERENCES public.django_content_type(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_user_groups auth_user_groups_group_id_97559544_fk_auth_group_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_groups
    ADD CONSTRAINT auth_user_groups_group_id_97559544_fk_auth_group_id FOREIGN KEY (group_id) REFERENCES public.auth_group(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_user_groups auth_user_groups_user_id_6a12ed8b_fk_auth_user_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_groups
    ADD CONSTRAINT auth_user_groups_user_id_6a12ed8b_fk_auth_user_id FOREIGN KEY (user_id) REFERENCES public.auth_user(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_user_user_permissions auth_user_user_permi_permission_id_1fbb5f2c_fk_auth_perm; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_user_permissions
    ADD CONSTRAINT auth_user_user_permi_permission_id_1fbb5f2c_fk_auth_perm FOREIGN KEY (permission_id) REFERENCES public.auth_permission(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_user_user_permissions auth_user_user_permissions_user_id_a95ead1b_fk_auth_user_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_user_permissions
    ADD CONSTRAINT auth_user_user_permissions_user_id_a95ead1b_fk_auth_user_id FOREIGN KEY (user_id) REFERENCES public.auth_user(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: django_admin_log django_admin_log_content_type_id_c4bce8eb_fk_django_co; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_admin_log
    ADD CONSTRAINT django_admin_log_content_type_id_c4bce8eb_fk_django_co FOREIGN KEY (content_type_id) REFERENCES public.django_content_type(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: django_admin_log django_admin_log_user_id_c564eba6_fk_auth_user_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_admin_log
    ADD CONSTRAINT django_admin_log_user_id_c564eba6_fk_auth_user_id FOREIGN KEY (user_id) REFERENCES public.auth_user(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: order_items order_items_order_id_412ad78b_fk_orders_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_order_id_412ad78b_fk_orders_id FOREIGN KEY (order_id) REFERENCES public.orders(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: order_items order_items_product_id_dd557d5a_fk_products_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_product_id_dd557d5a_fk_products_id FOREIGN KEY (product_id) REFERENCES public.products(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: orders orders_client_id_67f0b211_fk_clients_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_client_id_67f0b211_fk_clients_id FOREIGN KEY (client_id) REFERENCES public.clients(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: orders orders_courier_id_1aa0ca80_fk_users_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_courier_id_1aa0ca80_fk_users_id FOREIGN KEY (courier_id) REFERENCES public.users(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: orders orders_delivery_address_id_e5955160_fk_addresses_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_delivery_address_id_e5955160_fk_addresses_id FOREIGN KEY (delivery_address_id) REFERENCES public.addresses(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: orders orders_payment_method_id_dfb69856_fk_payment_methods_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_payment_method_id_dfb69856_fk_payment_methods_id FOREIGN KEY (payment_method_id) REFERENCES public.payment_methods(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: orders orders_pickup_address_id_a8fad629_fk_addresses_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pickup_address_id_a8fad629_fk_addresses_id FOREIGN KEY (pickup_address_id) REFERENCES public.addresses(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: orders orders_status_id_e763064e_fk_order_statuses_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_status_id_e763064e_fk_order_statuses_id FOREIGN KEY (status_id) REFERENCES public.order_statuses(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: payments payments_order_id_6086ad70_fk_orders_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_order_id_6086ad70_fk_orders_id FOREIGN KEY (order_id) REFERENCES public.orders(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: payments payments_payment_method_id_83b27e37_fk_payment_methods_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_payment_method_id_83b27e37_fk_payment_methods_id FOREIGN KEY (payment_method_id) REFERENCES public.payment_methods(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: reviews reviews_order_id_35d02b74_fk_orders_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_order_id_35d02b74_fk_orders_id FOREIGN KEY (order_id) REFERENCES public.orders(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: users users_role_id_1900a745_fk_roles_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_role_id_1900a745_fk_roles_id FOREIGN KEY (role_id) REFERENCES public.roles(id) DEFERRABLE INITIALLY DEFERRED;


--
-- PostgreSQL database dump complete
--

\unrestrict Ra4bf5XeBEPSnqi9GSN9nKP76c9NBGQblCPjCFxiLgxHrLzTUdOsE9drcXzZFMZ

