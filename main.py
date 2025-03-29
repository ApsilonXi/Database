import psycopg2
from tkinter import *
from tkinter import ttk, messagebox, filedialog
from datetime import datetime
import os
import subprocess

class WarehouseApp:
    def __init__(self, root, login, password, active_user):
        self.root = root
        self.root.title("Управление складом")
        self.root.geometry("1200x800")
        self.current_user = login
        self.user_password = password
        self.initial_state = None
        self.is_search_active = False  
        
        # Добавляем атрибуты для хранения условий поиска
        self.current_search_conditions = {
            'invoice': None,
            'warehouse': None,
            'counteragent': None,
            'employee': None
        }
        
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)
        
        try:
            if active_user:
                self.conn = active_user
            else:
                try:
                    self.conn = psycopg2.connect(
                        host="127.0.0.1",
                        user=login,
                        password=password,
                        database="Warehouse_DB"
                    )
                    print("[INFO] PostgreSQL connection open.")
                except Exception as ex:
                    print(f"[ERROR] Connection failed: {ex}")
                    messagebox.showerror("Ошибка подключения", f"Не удалось подключиться к базе данных: {str(ex)}")
                    self.root.destroy()
                    return
                    
            self.cursor = self.conn.cursor()
            self.determine_user_permissions()
            
            self.save_initial_state()
            
            self.status_bar = Label(root, text=f"Вход выполнен как: {login} | Готово", bd=1, relief=SUNKEN, anchor=W)
            self.status_bar.pack(side=BOTTOM, fill=X)
            
            self.notebook = ttk.Notebook(root)
            self.notebook.pack(fill=BOTH, expand=True)
            
            if self.can_access_warehouse:
                self.create_warehouse_tab()
                
            if self.can_access_invoices:
                self.create_invoice_tab()
                
            if self.can_access_counteragents:
                self.create_counteragent_tab()
                
            if self.can_access_employees:
                self.create_employee_tab()
            
            self.create_settings_tab()
                
        except psycopg2.Error as e:
            print(f"[TRANSACTION ERROR] Initialization failed: {e}")
            messagebox.showerror("Ошибка подключения", f"Не удалось подключиться к базе данных: {str(e)}")
            self.root.destroy()

    def on_close(self):
        if hasattr(self, 'initial_transaction'):
            self.initial_transaction.close()
        if hasattr(self, 'conn') and self.conn:
            self.conn.close()
            print("[INFO] PostgreSQL connection closed.")
        self.root.destroy()

    def create_context_menu(self, event, tree, menu_items):
        """Создание контекстного меню для Treeview с добавлением кнопки обновления"""
        item = tree.identify_row(event.y)
        if not item:
            return
            
        tree.selection_set(item)
        menu = Menu(self.root, tearoff=0)
        for label, command in menu_items:
            if command:
                menu.add_command(label=label, command=command)
            else:
                menu.add_separator()
        
        # Добавляем пункт для принудительного обновления
        menu.add_separator()
        if tree == self.invoice_tree:
            menu.add_command(label="Обновить таблицу", command=lambda: [self.current_search_conditions.update({'invoice': None}), self.load_invoices()])
        elif tree == self.warehouse_tree:
            menu.add_command(label="Обновить таблицу", command=lambda: [self.current_search_conditions.update({'warehouse': None}), self.load_warehouse()])
        elif tree == self.counteragent_tree:
            menu.add_command(label="Обновить таблицу", command=lambda: [self.current_search_conditions.update({'counteragent': None}), self.load_counteragents()])
        elif tree == self.employee_tree:
            menu.add_command(label="Обновить таблицу", command=lambda: [self.current_search_conditions.update({'employee': None}), self.load_employees()])
        
        try:
            menu.tk_popup(event.x_root, event.y_root)
        finally:
            menu.grab_release()

    def get_table_order(self):
        """Возвращает порядок таблиц для отката с учетом зависимостей"""
        return [
            'invoice_detail',
            'invoice_employee',
            'invoice',
            'details',
            'counteragent',
            'employee',
            'shelf',
            'rack',
            'room',
            'warehouse',
            'log_table'
        ]
    
    def refresh_affected_tab(self, table_name):
        """Обновляет вкладку, соответствующую измененной таблице"""
        if not self.is_search_active:
            if table_name in ['invoice', 'invoice_detail', 'invoice_employee'] and hasattr(self, 'invoice_tree'):
                self.load_invoices()
            elif table_name == 'details' and hasattr(self, 'warehouse_tree'):
                self.load_warehouse()
            elif table_name == 'counteragent' and hasattr(self, 'counteragent_tree'):
                self.load_counteragents()
            elif table_name == 'employee' and hasattr(self, 'employee_tree'):
                self.load_employees()
        else:
            # Если поиск активен, не обновляем автоматически
            pass

    def refresh_all_tabs(self):
        """Обновляет все вкладки приложения"""
        if not self.is_search_active:
            if hasattr(self, 'invoice_tree'):
                self.load_invoices()
            if hasattr(self, 'warehouse_tree'):
                self.load_warehouse()
            if hasattr(self, 'counteragent_tree'):
                self.load_counteragents()
            if hasattr(self, 'employee_tree'):
                self.load_employees()
        else:
            # Если поиск активен, не обновляем автоматически
            pass
    
    def create_settings_tab(self):
        """Создает вкладку настроек для пользователя"""
        tab = Frame(self.notebook)
        self.notebook.add(tab, text="Настройки")
        
        # Основной фрейм для кнопок
        frame = Frame(tab)
        frame.pack(pady=20)
        
        # Кнопка отката для всех пользователей
        btn_rollback = Button(frame, text="Откат системы к началу текущей сессии", 
                            command=self.rollback_to_initial_state)
        btn_rollback.pack(pady=10, fill=X)
        
        # Новая кнопка для отмены последней операции
        btn_undo = Button(frame, text="Отменить последнюю операцию", 
                        command=self.undo_last_operation)
        btn_undo.pack(pady=10, fill=X)
        
        # Дополнительные функции для владельца
        if self.current_user == 'owner':
            btn_backup = Button(frame, text="Резервное копирование", 
                            command=self.create_backup)
            btn_backup.pack(pady=10, fill=X)
            
            btn_restore = Button(frame, text="Загрузка резервной копии", 
                            command=self.restore_from_backup)
            btn_restore.pack(pady=10, fill=X)
            
            btn_edit_warehouse = Button(frame, text="Редактирование структуры склада", 
                                    command=self.edit_warehouse_structure)
            btn_edit_warehouse.pack(pady=10, fill=X)

    def undo_last_operation(self):
        """Отменяет последнюю операцию с учетом зависимостей"""
        try:
            if not hasattr(self, 'initial_state_time') or not self.initial_state_time:
                messagebox.showinfo("Информация", "Не удалось определить начало сессии")
                return

            # Получаем ID последней операции UNDO (если есть)
            self.cursor.execute("""
                SELECT record_id FROM log_table
                WHERE action_type = 'UNDO'
                AND action_time >= %s
                ORDER BY log_id DESC
                LIMIT 1
            """, (self.initial_state_time,))
            last_undo = self.cursor.fetchone()
            last_undo_id = last_undo[0] if last_undo else None

            # Получаем последнюю операцию текущей сессии
            query = """
                SELECT lt.log_id, lt.table_name, lt.action_type, 
                    lt.record_id, lt.old_values, lt.new_values
                FROM log_table lt
                WHERE lt.action_type NOT IN ('UNDO', 'ROLLBACK')
                AND lt.action_time >= %s
            """
            params = [self.initial_state_time]

            if last_undo_id:
                query += " AND lt.log_id > %s"
                params.append(last_undo_id)

            query += """
                ORDER BY 
                    CASE table_name
                        WHEN 'invoice_detail' THEN 1
                        WHEN 'invoice_employee' THEN 2
                        WHEN 'invoice' THEN 3
                        WHEN 'details' THEN 4
                        WHEN 'counteragent' THEN 5
                        WHEN 'employee' THEN 6
                        WHEN 'shelf' THEN 7
                        WHEN 'rack' THEN 8
                        WHEN 'room' THEN 9
                        WHEN 'warehouse' THEN 10
                        ELSE 11
                    END,
                    CASE action_type
                        WHEN 'DELETE' THEN 1
                        WHEN 'UPDATE' THEN 2
                        WHEN 'INSERT' THEN 3
                        ELSE 4
                    END,
                    log_id DESC
                LIMIT 1
            """

            self.cursor.execute(query, params)
            last_op = self.cursor.fetchone()
            
            if not last_op:
                messagebox.showinfo("Информация", "Нет операций для отмены в текущей сессии")
                return
                
            log_id, table, action, record_id, old_values, new_values = last_op
            
            # Получаем первичный ключ для таблицы
            pk = self.get_primary_key(table)
            if not pk:
                messagebox.showerror("Ошибка", f"Не удалось определить первичный ключ для таблицы {table}")
                return
            
            # Начинаем транзакцию
            self.cursor.execute("BEGIN")
            
            try:
                if action == 'INSERT':
                    # Для связанных таблиц сначала проверяем зависимости
                    if table in ['invoice_detail', 'invoice_employee']:
                        self.cursor.execute(f"""
                            SELECT invoiceid FROM {table} 
                            WHERE {pk} = %s
                        """, (record_id,))
                        invoice_id = self.cursor.fetchone()[0]
                        self.cursor.execute("""
                            SELECT 1 FROM invoice 
                            WHERE invoice_id = %s
                        """, (invoice_id,))
                        if not self.cursor.fetchone():
                            messagebox.showwarning("Предупреждение", 
                                "Невозможно отменить операцию: связанная накладная уже удалена")
                            self.conn.rollback()
                            return
                    
                    self.cursor.execute(f"""
                        DELETE FROM {table} 
                        WHERE {pk} = %s
                        RETURNING *
                    """, (record_id,))
                    
                elif action == 'DELETE' and old_values:
                    # Проверяем зависимости для вставки
                    if table in ['invoice_detail', 'invoice_employee'] and 'invoiceid' in old_values:
                        self.cursor.execute("""
                            SELECT 1 FROM invoice 
                            WHERE invoice_id = %s
                        """, (old_values['invoiceid'],))
                        if not self.cursor.fetchone():
                            messagebox.showwarning("Предупреждение", 
                                "Невозможно отменить операцию: связанная накладная не существует")
                            self.conn.rollback()
                            return
                    
                    columns = ', '.join(old_values.keys())
                    values = ', '.join(['%s'] * len(old_values))
                    self.cursor.execute(f"""
                        INSERT INTO {table} ({columns}) 
                        VALUES ({values})
                        RETURNING *
                    """, list(old_values.values()))
                    
                elif action == 'UPDATE' and old_values:
                    set_clause = ', '.join([f"{k} = %s" for k in old_values.keys()])
                    self.cursor.execute(f"""
                        UPDATE {table} 
                        SET {set_clause}
                        WHERE {pk} = %s
                        RETURNING *
                    """, list(old_values.values()) + [record_id])
                
                # Фиксируем отмену в логах
                import json
                old_values_json = json.dumps(new_values) if new_values else None
                new_values_json = json.dumps(old_values) if old_values else None
                
                self.cursor.execute("""
                    INSERT INTO log_table 
                    (table_name, action_type, record_id, old_values, new_values)
                    VALUES (%s, 'UNDO', %s, %s, %s)
                """, (table, log_id, old_values_json, new_values_json))
                
                self.conn.commit()
                self.refresh_affected_tab(table)
                messagebox.showinfo("Успех", "Последняя операция успешно отменена")
                
            except Exception as e:
                self.conn.rollback()
                messagebox.showerror("Ошибка", f"Не удалось отменить операцию: {str(e)}")
                
        except Exception as e:
            messagebox.showerror("Ошибка", f"Ошибка при отмене операции: {str(e)}")

    def save_initial_state(self):
        """Сохраняет информацию о начальной точке отката"""
        try:
            self.cursor.execute("SELECT current_timestamp")
            self.initial_state_time = self.cursor.fetchone()[0]
            print(f"[INFO] Saved initial state time: {self.initial_state_time}")
        except Exception as e:
            print(f"[ERROR] Failed to save initial state: {e}")
            self.initial_state_time = None

    def rollback_to_initial_state(self):
        """Откатывает изменения с учетом зависимостей между таблицами"""
        if not self.initial_state_time:
            messagebox.showwarning("Предупреждение", "Не удалось определить начальное состояние сессии")
            return
            
        if messagebox.askyesno("Подтверждение", 
                            "Вы уверены, что хотите откатить все изменения текущей сессии?"):
            try:
                # Получаем список изменений из логов, упорядоченный по таблицам
                self.cursor.execute("""
                    SELECT table_name, action_type, record_id, old_values
                    FROM log_table
                    WHERE action_time >= %s
                    AND log_id > COALESCE((SELECT MAX(log_id) FROM log_table WHERE action_type = 'ROLLBACK'), 0)
                    ORDER BY 
                        CASE table_name
                            WHEN 'invoice_detail' THEN 1
                            WHEN 'invoice_employee' THEN 2
                            WHEN 'invoice' THEN 3
                            WHEN 'details' THEN 4
                            WHEN 'counteragent' THEN 5
                            WHEN 'employee' THEN 6
                            WHEN 'shelf' THEN 7
                            WHEN 'rack' THEN 8
                            WHEN 'room' THEN 9
                            WHEN 'warehouse' THEN 10
                            ELSE 11
                        END,
                        CASE action_type
                            WHEN 'DELETE' THEN 1
                            WHEN 'UPDATE' THEN 2
                            WHEN 'INSERT' THEN 3
                            ELSE 4
                        END,
                        log_id DESC
                """, (self.initial_state_time,))
                
                changes = self.cursor.fetchall()
                
                if not changes:
                    messagebox.showinfo("Информация", "Нет изменений для отката")
                    return
                
                # Начинаем транзакцию
                self.cursor.execute("BEGIN")
                
                # Обрабатываем изменения в правильном порядке
                for table, action, record_id, old_values in changes:
                    try:
                        pk = self.get_primary_key(table)
                        if not pk:
                            print(f"[WARNING] Не удалось определить PK для таблицы {table}")
                            continue
                        
                        if action == 'INSERT':
                            # Проверяем, существует ли запись перед удалением
                            self.cursor.execute(f"""
                                SELECT 1 FROM {table} 
                                WHERE {pk} = %s
                            """, (record_id,))
                            if self.cursor.fetchone():
                                self.cursor.execute(f"""
                                    DELETE FROM {table} 
                                    WHERE {pk} = %s
                                """, (record_id,))
                                
                        elif action == 'DELETE' and old_values:
                            # Проверяем зависимости для вставки
                            if table == 'invoice_detail' or table == 'invoice_employee':
                                # Проверяем существование invoice
                                if 'invoiceid' in old_values:
                                    self.cursor.execute("""
                                        SELECT 1 FROM invoice 
                                        WHERE invoice_id = %s
                                    """, (old_values['invoiceid'],))
                                    if not self.cursor.fetchone():
                                        print(f"[WARNING] Пропуск вставки в {table}, invoice не существует")
                                        continue
                            
                            # Проверяем, не существует ли запись перед вставкой
                            self.cursor.execute(f"""
                                SELECT 1 FROM {table} 
                                WHERE {pk} = %s
                            """, (record_id,))
                            if not self.cursor.fetchone():
                                columns = ', '.join(old_values.keys())
                                values = ', '.join(['%s'] * len(old_values))
                                self.cursor.execute(f"""
                                    INSERT INTO {table} ({columns}) 
                                    VALUES ({values})
                                """, list(old_values.values()))
                                
                        elif action == 'UPDATE' and old_values:
                            # Всегда пытаемся выполнить UPDATE
                            set_clause = ', '.join([f"{k} = %s" for k in old_values.keys()])
                            self.cursor.execute(f"""
                                UPDATE {table} 
                                SET {set_clause}
                                WHERE {pk} = %s
                            """, list(old_values.values()) + [record_id])
                            
                    except psycopg2.Error as e:
                        print(f"[WARNING] Failed to revert {action} on {table}.{record_id}: {e}")
                        # Продолжаем выполнение несмотря на ошибку
                        self.conn.rollback()
                        self.cursor.execute("SAVEPOINT rollback_continue")
                        continue
                
                # Помечаем откат в логах
                self.cursor.execute("""
                    INSERT INTO log_table (table_name, action_type, record_id)
                    VALUES ('SYSTEM', 'ROLLBACK', %s)
                """, (len(changes),))
                
                self.conn.commit()
                
                # Обновляем данные во всех вкладках
                self.refresh_all_tabs()
                
                messagebox.showinfo("Успех", "Система успешно откачена к началу сессии")
                
            except Exception as e:
                messagebox.showerror("Ошибка", f"Не удалось выполнить откат: {str(e)}")
                self.conn.rollback()

    def get_primary_key(self, table_name):
        """Возвращает имя первичного ключа для таблицы с обработкой исключений"""
        # Словарь соответствий имен таблиц и их первичных ключей
        pk_mapping = {
            'warehouse': 'warehouse_id',
            'room': 'room_id',
            'rack': 'rack_id',
            'shelf': 'shelf_id',
            'details': 'detail_id',
            'counteragent': 'counteragent_id',
            'invoice': 'invoice_id',
            'invoice_detail': 'invoiceID',  
            'employee': 'employee_id',
            'invoice_employee': 'invoiceID',  
            'log_table': 'log_id'
        }
        
        # Возвращаем PK из словаря или пытаемся определить автоматически
        if table_name in pk_mapping:
            return pk_mapping[table_name]
        
        try:
            self.cursor.execute("""
                SELECT a.attname
                FROM pg_index i
                JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
                WHERE i.indrelid = %s::regclass AND i.indisprimary
            """, (table_name,))
            result = self.cursor.fetchone()
            return result[0] if result else None
        except:
            return None

    def create_backup(self):
        """Создает резервную копию базы данных"""
        try:
            # Запрашиваем место сохранения
            backup_file = filedialog.asksaveasfilename(
                defaultextension=".backup",
                filetypes=[("Backup files", "*.backup"), ("All files", "*.*")],
                title="Сохранить резервную копию как"
            )
            
            if not backup_file:
                return
                
            # Создаем переменные окружения с паролем
            env = os.environ.copy()
            env['PGPASSWORD'] = '12345'  # Замените на ваш реальный пароль PostgreSQL
            
            # Выполняем pg_dump через subprocess
            command = [
                r'C:\Program Files\PostgreSQL\17\bin\pg_dump',
                '-h', '127.0.0.1',
                '-U', 'postgres',
                '-d', 'Warehouse_DB',
                '-F', 'c',  # custom format
                '-f', backup_file
            ]
            
            # Запускаем процесс с переменными окружения
            process = subprocess.Popen(command, 
                                    env=env,
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE)
            
            # Ждем завершения процесса
            stdout, stderr = process.communicate()
            
            if process.returncode == 0:
                messagebox.showinfo("Успех", f"Резервная копия успешно создана: {backup_file}")
            else:
                error_msg = stderr.decode('utf-8') if stderr else "Неизвестная ошибка"
                messagebox.showerror("Ошибка", f"Не удалось создать резервную копию: {error_msg}")
        except Exception as e:
            messagebox.showerror("Ошибка", f"Ошибка при создании резервной копии: {str(e)}")

    def restore_from_backup(self):
        """Восстанавливает базу данных из резервной копии"""
        try:
            # Запрашиваем файл резервной копии
            backup_file = filedialog.askopenfilename(
                filetypes=[("Backup files", "*.backup"), ("All files", "*.*")],
                title="Выберите файл резервной копии"
            )
            
            if not backup_file:
                return
                
            if not messagebox.askyesno("Подтверждение", 
                                    "Вы уверены, что хотите восстановить базу данных из резервной копии? Все текущие данные будут потеряны!"):
                return
                
            # Закрываем текущее соединение
            self.conn.close()
            
            # Создаем переменные окружения с паролем
            env = os.environ.copy()
            env['PGPASSWORD'] = '12345'  # Замените на ваш реальный пароль PostgreSQL
            
            # Выполняем pg_restore через subprocess
            command = [
                r'C:\Program Files\PostgreSQL\17\bin\pg_restore',
                '-h', '127.0.0.1',
                '-U', 'postgres',
                '-d', 'Warehouse_DB',
                '-c',  # Очистить базу перед восстановлением
                backup_file
            ]
            
            # Запускаем процесс с переменными окружения
            process = subprocess.Popen(command, 
                                    env=env,
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE)
            
            # Ждем завершения процесса
            stdout, stderr = process.communicate()
            
            if process.returncode == 0:
                messagebox.showinfo("Успех", "База данных успешно восстановлена из резервной копии")
                
                # Перезапускаем приложение
                self.root.destroy()
                main_win = Tk()
                app = WarehouseApp(main_win, self.current_user, self.user_password, None)
                main_win.mainloop()
            else:
                error_msg = stderr.decode('utf-8') if stderr else "Неизвестная ошибка"
                messagebox.showerror("Ошибка", f"Не удалось восстановить базу данных: {error_msg}")
                # Пытаемся восстановить соединение
                self.conn = psycopg2.connect(
                    host="127.0.0.1",
                    user=self.current_user,
                    password=self.user_password,
                    database="Warehouse_DB"
                )
                self.cursor = self.conn.cursor()
        except Exception as e:
            messagebox.showerror("Ошибка", f"Ошибка при восстановлении из резервной копии: {str(e)}")
            # Пытаемся восстановить соединение
            try:
                self.conn = psycopg2.connect(
                    host="127.0.0.1",
                    user=self.current_user,
                    password=self.user_password,
                    database="Warehouse_DB"
                )
                self.cursor = self.conn.cursor()
            except:
                self.root.destroy()

    def create_structure_tab(self, parent, table_name, columns_ru):
        """Создает вкладку для редактирования структуры склада с русскими названиями"""
        # Соответствие русских названий английским
        columns_map = {
            "warehouse": {
                "Номер склада": "warehouse_number",
                "Адрес": "address"
            },
            "room": {
                "Склад": "warehouseid",
                "Номер комнаты": "room_number"
            },
            "rack": {
                "Комната": "roomid",
                "Номер стеллажа": "rack_number"
            },
            "shelf": {
                "Стеллаж": "rackid",
                "Номер полки": "shelf_number"
            }
        }
        
        # Получаем английские названия колонок
        columns_en = [columns_map[table_name][col] for col in columns_ru]
        
        # Treeview для отображения данных
        tree = ttk.Treeview(parent, columns=("id", *columns_ru), show="headings")
        tree.heading("id", text="ID")
        
        # Настраиваем заголовки и колонки
        for col in columns_ru:
            tree.heading(col, text=col)
            tree.column(col, width=150)
        
        tree.column("id", width=50)
        
        # Scrollbar
        scroll = ttk.Scrollbar(parent, command=tree.yview)
        scroll.pack(side=RIGHT, fill=Y)
        tree.configure(yscrollcommand=scroll.set)
        
        tree.pack(fill=BOTH, expand=True)
        
        # Функция загрузки данных
        def load_data(reset_search=False):
            """Загружает данные с учетом текущих условий поиска или сбрасывает их"""
            if reset_search:
                self.current_search_conditions[table_name] = None
            
            tree.delete(*tree.get_children())
            
            if self.current_search_conditions.get(table_name):
                # Загружаем с учетом текущего поиска
                conditions = self.current_search_conditions[table_name]['conditions']
                params = self.current_search_conditions[table_name]['params']
                query = f"SELECT * FROM {table_name} WHERE " + " AND ".join(conditions) + " ORDER BY 1"
                self.cursor.execute(query, params)
            else:
                # Загружаем все данные
                self.cursor.execute(f"SELECT * FROM {table_name} ORDER BY 1")
            
            for row in self.cursor.fetchall():
                # Преобразуем ID в читаемые значения для внешних ключей
                formatted_row = [row[0]]  # ID
                for i, col in enumerate(columns_en):
                    if col.endswith("id"):
                        # Для внешних ключей получаем связанные номера
                        ref_table = col.replace("id", "")
                        self.cursor.execute(f"SELECT {ref_table}_number FROM {ref_table} WHERE {ref_table}_id = %s", (row[i+1],))
                        ref_number = self.cursor.fetchone()
                        formatted_row.append(ref_number[0] if ref_number else "N/A")
                    else:
                        formatted_row.append(row[i+1])
                tree.insert("", END, values=formatted_row)
        
        # Функция поиска для конкретной вкладки
        def search_items():
            search_window = Toplevel(self.root)
            search_window.title(f"Поиск в {table_name}")
            
            # Создаем элементы формы для поиска
            Label(search_window, text="Критерии поиска:").grid(row=0, column=0, columnspan=2, pady=5)
            
            search_vars = []
            for i, col in enumerate(columns_ru):
                Label(search_window, text=f"{col}:").grid(row=i+1, column=0, padx=5, pady=5, sticky=W)
                var = StringVar()
                
                # Для внешних ключей делаем выпадающие списки
                if columns_en[i].endswith("id"):
                    ref_table = columns_en[i].replace("id", "")
                    self.cursor.execute(f"SELECT {ref_table}_number FROM {ref_table} ORDER BY {ref_table}_number")
                    options = [str(row[0]) for row in self.cursor.fetchall()]
                    combo = ttk.Combobox(search_window, textvariable=var, values=options)
                    combo.grid(row=i+1, column=1, padx=5, pady=5, sticky=EW)
                else:
                    Entry(search_window, textvariable=var).grid(row=i+1, column=1, padx=5, pady=5, sticky=EW)
                
                search_vars.append(var)
            
            def perform_search():
                try:
                    conditions = []
                    params = []
                    
                    for i, col in enumerate(columns_en):
                        search_text = search_vars[i].get()
                        if search_text:
                            if col.endswith("id"):
                                # Для внешних ключей ищем по номеру
                                ref_table = col.replace("id", "")
                                self.cursor.execute(f"""
                                    SELECT {ref_table}_id FROM {ref_table} 
                                    WHERE {ref_table}_number = %s
                                """, (search_text,))
                                ref_id = self.cursor.fetchone()
                                if ref_id:
                                    conditions.append(f"{col} = %s")
                                    params.append(ref_id[0])
                            else:
                                # Для обычных полей используем LIKE
                                conditions.append(f"{col}::text LIKE %s")
                                params.append(f"%{search_text}%")
                    
                    # Сохраняем условия поиска
                    self.current_search_conditions[table_name] = {
                        'conditions': conditions,
                        'params': params
                    }
                    
                    # Обновляем данные с учетом поиска
                    load_data(False)
                    search_window.destroy()
                    
                except Exception as e:
                    messagebox.showerror("Ошибка", f"Ошибка поиска: {str(e)}")
                    self.conn.rollback()
            
            Button(search_window, text="Найти", command=perform_search).grid(
                row=len(columns_ru)+1, column=0, padx=5, pady=10, sticky=EW)
            Button(search_window, text="Сбросить", command=lambda: [self.current_search_conditions.update({table_name: None}), load_data(False), search_window.destroy()]).grid(
                row=len(columns_ru)+1, column=1, padx=5, pady=10, sticky=EW)
        
        # Контекстное меню
        menu = Menu(parent, tearoff=0)
        menu.add_command(label="Добавить", command=lambda: self.add_structure_item(table_name, columns_en, columns_ru, lambda: load_data(False)))
        menu.add_command(label="Изменить", command=lambda: self.edit_structure_item(tree, table_name, columns_en, columns_ru, lambda: load_data(False)))
        menu.add_command(label="Удалить", command=lambda: self.delete_structure_item(tree, table_name, lambda: load_data(False)))
        menu.add_separator()
        menu.add_command(label="Найти", command=search_items)  
        menu.add_separator()
        menu.add_command(label="Обновить список", command=lambda: load_data(False))  # Обновит текущий список (после поиска)
        menu.add_command(label="Обновить таблицу", command=lambda: load_data(True))  # Сбросит поиск и загрузит все данные
        
        def show_context_menu(event):
            item = tree.identify_row(event.y)
            if item:
                tree.selection_set(item)
                menu.post(event.x_root, event.y_root)
        
        tree.bind("<Button-3>", show_context_menu)
        load_data(False)  # Первоначальная загрузка

    def edit_warehouse_structure(self):
        """Редактирование структуры склада (склады, комнаты, стеллажи, полки)"""
        # Создаем новое окно для редактирования структуры
        edit_window = Toplevel(self.root)
        edit_window.title("Редактирование структуры склада")
        edit_window.geometry("800x600")
        
        # Скрываем основное окно
        self.root.withdraw()
        
        # Обработчик закрытия окна редактирования
        def on_edit_window_close():
            # Показываем основное окно снова
            self.root.deiconify()
            # Закрываем окно редактирования
            edit_window.destroy()
        
        # Привязываем обработчик закрытия окна
        edit_window.protocol("WM_DELETE_WINDOW", on_edit_window_close)
        
        notebook = ttk.Notebook(edit_window)
        notebook.pack(fill=BOTH, expand=True)
        
        # Вкладка для складов
        warehouse_tab = Frame(notebook)
        notebook.add(warehouse_tab, text="Склады")
        self.create_structure_tab(warehouse_tab, "warehouse", ["Номер склада", "Адрес"])
        
        # Вкладка для комнат
        room_tab = Frame(notebook)
        notebook.add(room_tab, text="Комнаты")
        self.create_structure_tab(room_tab, "room", ["Склад", "Номер комнаты"])
        
        # Вкладка для стеллажей
        rack_tab = Frame(notebook)
        notebook.add(rack_tab, text="Стеллажи")
        self.create_structure_tab(rack_tab, "rack", ["Комната", "Номер стеллажа"])
        
        # Вкладка для полок
        shelf_tab = Frame(notebook)
        notebook.add(shelf_tab, text="Полки")
        self.create_structure_tab(shelf_tab, "shelf", ["Стеллаж", "Номер полки"])

    def add_structure_item(self, table_name, columns_en, columns_ru, callback):
        """Добавляет новый элемент структуры склада с проверкой уникальности"""
        add_window = Toplevel(self.root)
        add_window.title(f"Добавить в {table_name}")
        
        entries = []
        labels = []
        
        for i, (col_en, col_ru) in enumerate(zip(columns_en, columns_ru)):
            labels.append(Label(add_window, text=col_ru))
            labels[-1].grid(row=i, column=0, padx=5, pady=5, sticky=W)
            
            if col_en.endswith("id"):  # Это внешний ключ - делаем выпадающий список
                ref_table = col_en.replace("id", "")
                self.cursor.execute(f"SELECT {ref_table}_id, {ref_table}_number FROM {ref_table}")
                options = [f"{num} (ID: {id})" for id, num in self.cursor.fetchall()]
                
                var = StringVar()
                combo = ttk.Combobox(add_window, textvariable=var, values=options)
                combo.grid(row=i, column=1, padx=5, pady=5, sticky=EW)
                entries.append((var, True, col_en))  # True означает, что это combobox
            else:
                entry = Entry(add_window)
                entry.grid(row=i, column=1, padx=5, pady=5, sticky=EW)
                entries.append((entry, False, col_en))
        
        def save_item():
            try:
                values = []
                parent_id = None
                
                # Проверяем уникальность номера перед добавлением
                if table_name == "warehouse":
                    # Для склада проверяем уникальность номера склада
                    warehouse_number = entries[0][0].get()  # Первое поле - номер склада
                    self.cursor.execute("SELECT 1 FROM warehouse WHERE warehouse_number = %s", (warehouse_number,))
                    # Для склада проверяем уникальность адреса
                    address = entries[1][0].get()  # Второе поле - адрес
                    self.cursor.execute("SELECT 1 FROM warehouse WHERE address = %s", (address,))
                    if self.cursor.fetchone():
                        raise ValueError(f"Склад с номером {warehouse_number} уже существует")
                    if self.cursor.fetchone():
                        raise ValueError(f"Склад по адресу {address} уже существует")
                
                elif table_name == "room":
                    # Для комнаты проверяем уникальность номера комнаты в пределах склада
                    room_number = entries[1][0].get()  # Второе поле - номер комнаты
                    warehouse_id = entries[0][0].get().split("(ID: ")[1].replace(")", "").strip()
                    self.cursor.execute("""
                        SELECT 1 FROM room 
                        WHERE room_number = %s AND warehouseID = %s
                    """, (room_number, warehouse_id))
                    if self.cursor.fetchone():
                        raise ValueError(f"Комната с номером {room_number} уже существует в этом складе")
                
                elif table_name == "rack":
                    # Для стеллажа проверяем уникальность номера стеллажа в пределах комнаты
                    rack_number = entries[1][0].get()  # Второе поле - номер стеллажа
                    room_id = entries[0][0].get().split("(ID: ")[1].replace(")", "").strip()
                    self.cursor.execute("""
                        SELECT 1 FROM rack 
                        WHERE rack_number = %s AND roomID = %s
                    """, (rack_number, room_id))
                    if self.cursor.fetchone():
                        raise ValueError(f"Стеллаж с номером {rack_number} уже существует в этой комнате")
                
                elif table_name == "shelf":
                    # Для полки проверяем уникальность номера полки в пределах стеллажа
                    shelf_number = entries[1][0].get()  # Второе поле - номер полки
                    rack_id = entries[0][0].get().split("(ID: ")[1].replace(")", "").strip()
                    self.cursor.execute("""
                        SELECT 1 FROM shelf 
                        WHERE shelf_number = %s AND rackID = %s
                    """, (shelf_number, rack_id))
                    if self.cursor.fetchone():
                        raise ValueError(f"Полка с номером {shelf_number} уже существует на этом стеллаже")
                
                # Если проверки пройдены, собираем значения
                for entry, is_combo, col_en in entries:
                    if is_combo:
                        val = entry.get().split("(ID: ")[1].replace(")", "").strip()
                        values.append(val)
                    else:
                        values.append(entry.get())
                
                columns_str = ", ".join(columns_en)
                placeholders = ", ".join(["%s"] * len(columns_en))
                
                self.cursor.execute(
                    f"INSERT INTO {table_name} ({columns_str}) VALUES ({placeholders})",
                    values
                )
                
                self.conn.commit()
                add_window.destroy()
                messagebox.showinfo("Успех", "Запись успешно добавлена")
                # УБИРАЕМ автоматический вызов callback()
            except ValueError as ve:
                messagebox.showerror("Ошибка", str(ve))
            except Exception as e:
                self.conn.rollback()
                messagebox.showerror("Ошибка", f"Не удалось добавить запись: {str(e)}")
        
        Button(add_window, text="Сохранить", command=save_item).grid(
            row=len(columns_en), column=0, columnspan=2, pady=10)

    def edit_structure_item(self, tree, table_name, columns_en, columns_ru, callback):
        """Редактирует элемент структуры склада без автоматического обновления"""
        selected = tree.selection()
        if not selected:
            messagebox.showwarning("Предупреждение", "Выберите запись для редактирования")
            return
        
        item = tree.item(selected[0])
        item_id = item['values'][0]
        
        edit_window = Toplevel(self.root)
        edit_window.title(f"Изменить запись в {table_name}")
        
        # Получаем текущие данные
        self.cursor.execute(f"SELECT * FROM {table_name} WHERE {table_name}_id = %s", (item_id,))
        current_data = self.cursor.fetchone()
        
        entries = []
        labels = []
        
        for i, (col_en, col_ru) in enumerate(zip(columns_en, columns_ru)):
            labels.append(Label(edit_window, text=col_ru))
            labels[-1].grid(row=i, column=0, padx=5, pady=5, sticky=W)
            
            if col_en.endswith("id"):  # Это внешний ключ - делаем выпадающий список
                ref_table = col_en.replace("id", "")
                self.cursor.execute(f"SELECT {ref_table}_id, {ref_table}_number FROM {ref_table}")
                options = [f"{num} (ID: {id})" for id, num in self.cursor.fetchall()]
                
                # Находим текущее значение
                self.cursor.execute(f"SELECT {ref_table}_number FROM {ref_table} WHERE {ref_table}_id = %s", (current_data[i+1],))
                current_ref = self.cursor.fetchone()
                current_value = f"{current_ref[0]} (ID: {current_data[i+1]})" if current_ref else ""
                
                var = StringVar(value=current_value)
                combo = ttk.Combobox(edit_window, textvariable=var, values=options)
                combo.grid(row=i, column=1, padx=5, pady=5, sticky=EW)
                entries.append((var, True, col_en))
            else:
                entry = Entry(edit_window)
                entry.insert(0, str(current_data[i+1]))
                entry.grid(row=i, column=1, padx=5, pady=5, sticky=EW)
                entries.append((entry, False, col_en))
        
        def save_changes():
            try:
                # Проверяем уникальность номера перед обновлением
                if table_name == "warehouse":
                    # Для склада проверяем уникальность адреса
                    new_address = entries[1][0].get()
                    self.cursor.execute("""
                        SELECT 1 FROM warehouse 
                        WHERE address = %s AND warehouse_id != %s
                    """, (new_address, item_id))
                    # Для склада проверяем уникальность номера склада
                    warehouse_number = entries[0][0].get()
                    self.cursor.execute("""
                        SELECT 1 FROM warehouse 
                        WHERE warehouse_number = %s AND warehouse_id != %s
                    """, (warehouse_number, item_id))
                    if self.cursor.fetchone():
                        raise ValueError(f"Склад по адресу {new_address} уже существует")
                    if self.cursor.fetchone():
                        raise ValueError(f"Склад с номером {warehouse_number} уже существует")
                
                elif table_name == "room":
                    # Для комнаты проверяем уникальность номера комнаты в пределах склада
                    room_number = entries[1][0].get()
                    warehouse_id = entries[0][0].get().split("(ID: ")[1].replace(")", "").strip()
                    self.cursor.execute("""
                        SELECT 1 FROM room 
                        WHERE room_number = %s AND warehouseID = %s AND room_id != %s
                    """, (room_number, warehouse_id, item_id))
                    if self.cursor.fetchone():
                        raise ValueError(f"Комната с номером {room_number} уже существует в этом складе")
                
                elif table_name == "rack":
                    # Для стеллажа проверяем уникальность номера стеллажа в пределах комнаты
                    rack_number = entries[1][0].get()
                    room_id = entries[0][0].get().split("(ID: ")[1].replace(")", "").strip()
                    self.cursor.execute("""
                        SELECT 1 FROM rack 
                        WHERE rack_number = %s AND roomID = %s AND rack_id != %s
                    """, (rack_number, room_id, item_id))
                    if self.cursor.fetchone():
                        raise ValueError(f"Стеллаж с номером {rack_number} уже существует в этой комнате")
                
                elif table_name == "shelf":
                    # Для полки проверяем уникальность номера полки в пределах стеллажа
                    shelf_number = entries[1][0].get()
                    rack_id = entries[0][0].get().split("(ID: ")[1].replace(")", "").strip()
                    self.cursor.execute("""
                        SELECT 1 FROM shelf 
                        WHERE shelf_number = %s AND rackID = %s AND shelf_id != %s
                    """, (shelf_number, rack_id, item_id))
                    if self.cursor.fetchone():
                        raise ValueError(f"Полка с номером {shelf_number} уже существует на этом стеллаже")
                
                # Если проверки пройдены, собираем значения
                values = []
                for entry, is_combo, col_en in entries:
                    if is_combo:
                        val = entry.get().split("(ID: ")[1].replace(")", "").strip()
                        values.append(val)
                    else:
                        values.append(entry.get())
                
                set_clause = ", ".join([f"{col} = %s" for col in columns_en])
                
                self.cursor.execute(
                    f"UPDATE {table_name} SET {set_clause} WHERE {table_name}_id = %s",
                    values + [item_id]
                )
                
                self.conn.commit()
                edit_window.destroy()
                messagebox.showinfo("Успех", "Запись успешно обновлена")
                # УБИРАЕМ автоматический вызов callback()
            except ValueError as ve:
                messagebox.showerror("Ошибка", str(ve))
            except Exception as e:
                self.conn.rollback()
                messagebox.showerror("Ошибка", f"Не удалось обновить запись: {str(e)}")
        
        Button(edit_window, text="Сохранить", command=save_changes).grid(
            row=len(columns_en), column=0, columnspan=2, pady=10)

    def delete_structure_item(self, tree, table_name, callback):
        """Удаляет элемент структуры склада с обработкой ошибок"""
        selected = tree.selection()
        if not selected:
            messagebox.showwarning("Предупреждение", "Выберите запись для удаления")
            return
        
        item = tree.item(selected[0])
        item_id = item['values'][0]
        
        try:
            # Проверяем, есть ли связанные детали
            if table_name == "warehouse":
                self.cursor.execute("""
                    SELECT 1 FROM details WHERE shelfID IN (
                        SELECT shelf_id FROM shelf WHERE rackID IN (
                            SELECT rack_id FROM rack WHERE roomID IN (
                                SELECT room_id FROM room WHERE warehouseID = %s
                            )
                        )
                    ) LIMIT 1
                """, (item_id,))
            elif table_name == "room":
                self.cursor.execute("""
                    SELECT 1 FROM details WHERE shelfID IN (
                        SELECT shelf_id FROM shelf WHERE rackID IN (
                            SELECT rack_id FROM rack WHERE roomID = %s
                        )
                    ) LIMIT 1
                """, (item_id,))
            elif table_name == "rack":
                self.cursor.execute("""
                    SELECT 1 FROM details WHERE shelfID IN (
                        SELECT shelf_id FROM shelf WHERE rackID = %s
                    ) LIMIT 1
                """, (item_id,))
            elif table_name == "shelf":
                self.cursor.execute("""
                    SELECT 1 FROM details WHERE shelfID = %s LIMIT 1
                """, (item_id,))
            
            has_details = self.cursor.fetchone()
            
            if has_details:
                if not messagebox.askyesno(
                    "Подтверждение", 
                    "Это действие удалит все связанные детали. Продолжить?"
                ):
                    return
            
            # Выполняем удаление
            self.conn.commit()
            messagebox.showinfo("Успех", "Запись успешно удалена")
            # УБИРАЕМ автоматический вызов callback()
        except psycopg2.Error as e:
            self.conn.rollback()
            error_msg = f"Ошибка удаления: {str(e)}"
            if "нет доступа" in str(e):
                error_msg += "\n\nНедостаточно прав для выполнения операции. Обратитесь к администратору."
            messagebox.showerror("Ошибка", error_msg)

    def determine_user_permissions(self):
        self.can_access_invoices = False
        self.can_access_warehouse = False
        self.can_access_counteragents = False
        self.can_access_employees = False
        self.can_access_details = False
        
        self.can_edit_invoices = False
        self.can_edit_warehouse = False
        self.can_edit_counteragents = False
        self.can_edit_employees = False
        self.can_edit_details = False
        self.can_update_invoice_status = False  
        
        try:
            self.cursor.execute("""
                SELECT table_name, privilege_type 
                FROM information_schema.table_privileges 
                WHERE grantee = %s
            """, ('warehouse_'+self.current_user,))
            
            permissions = self.cursor.fetchall()
            
            for table, privilege in permissions:
                if table in ('invoice', 'invoice_details_view'):
                    self.can_access_invoices = True
                    if privilege in ('INSERT', 'UPDATE', 'DELETE'):
                        self.can_edit_invoices = True
                
                if table in ('warehouse', 'room', 'rack', 'shelf', 'warehouse_details_view'):
                    self.can_access_warehouse = True
                    if privilege in ('INSERT', 'UPDATE', 'DELETE'):
                        self.can_edit_warehouse = True
                
                if table == 'counteragent':
                    self.can_access_counteragents = True
                    if privilege in ('INSERT', 'UPDATE', 'DELETE'):
                        self.can_edit_counteragents = True
                
                if table == 'employee':
                    self.can_access_employees = True
                    if privilege in ('INSERT', 'UPDATE', 'DELETE'):
                        self.can_edit_employees = True
                
                if table == 'details':
                    self.can_access_details = True
                    if privilege in ('INSERT', 'UPDATE', 'DELETE'):
                        self.can_edit_details = True
            
            if self.current_user == 'clerk':
                self.can_edit_invoices = False
                self.can_update_invoice_status = True  
            
        except psycopg2.Error as e:
            print(f"[PERMISSION ERROR] Failed to check permissions: {e}")
            self.status_bar.config(text=f"Ошибка проверки прав доступа: {str(e)}")
        except psycopg2.Error as e:
            print(f"[VIEW ERROR] Failed to access view: {e}")
            messagebox.showerror("Ошибка", "Не удалось получить доступ к данным. Проверьте права доступа.")

    def create_invoice_tab(self):
        """Создание вкладки для работы с накладными с учетом прав доступа"""
        tab = Frame(self.notebook)
        self.notebook.add(tab, text="Накладные")
        
        # Таблица накладных
        columns = ("ID", "Контрагент", "Дата", "Тип", "Статус", "Деталь", "Кол-во", "Ответственный")
        self.invoice_tree = ttk.Treeview(tab, columns=columns, show="headings")
        
        for col in columns:
            self.invoice_tree.heading(col, text=col)
        
        self.invoice_tree.column("ID", width=50)
        self.invoice_tree.column("Контрагент", width=150)
        self.invoice_tree.column("Дата", width=120)
        self.invoice_tree.column("Тип", width=100)
        self.invoice_tree.column("Статус", width=100)
        self.invoice_tree.column("Деталь", width=150)
        self.invoice_tree.column("Кол-во", width=70)
        self.invoice_tree.column("Ответственный", width=150)
        
        scroll = ttk.Scrollbar(tab, command=self.invoice_tree.yview)
        scroll.pack(side=RIGHT, fill=Y)
        self.invoice_tree.configure(yscrollcommand=scroll.set)
        
        self.invoice_tree.pack(fill=BOTH, expand=True)
        
        # Контекстное меню
        menu_items = []
        if self.can_edit_invoices:
            menu_items.extend([
                ("Добавить накладную", self.add_invoice),
                ("Изменить накладную", self.edit_invoice),
                ("Удалить накладную", self.delete_invoice),
                (None, None)  # разделитель
            ])
        elif self.can_update_invoice_status:
            menu_items.extend([
                ("Обновить статус", self.update_invoice_status),
                (None, None)  # разделитель
            ])
        
        # Добавляем пункт поиска для всех пользователей
        menu_items.extend([
            ("Найти накладную", self.search_invoice),
            (None, None),  # разделитель
            ("Обновить список", self.load_invoices)
        ])
        
        self.invoice_tree.bind("<Button-3>", lambda e: self.create_context_menu(e, self.invoice_tree, menu_items))
        self.invoice_tree.bind("<Delete>", lambda e: self.delete_invoice())
        
        # Загрузка данных
        self.load_invoices()
    
    def update_invoice_status(self):
        selected = self.invoice_tree.selection()
        if not selected:
            messagebox.showwarning("Предупреждение", "Выберите накладную для обновления статуса")
            return
        
        try:
            item = self.invoice_tree.item(selected[0])
            invoice_id = item['values'][0]
            current_status = item['values'][4] == 'Завершено'
            
            status_window = Toplevel(self.root)
            status_window.title("Обновление статуса накладной")
            
            Label(status_window, text="Новый статус:").pack(padx=5, pady=5)
            
            status_var = StringVar()
            status_var.set("Завершено" if current_status else "В процессе")
            
            status_combobox = ttk.Combobox(status_window, textvariable=status_var, 
                                        values=["В процессе", "Завершено"])
            status_combobox.pack(padx=5, pady=5)
            
            def save_status():
                try:
                    new_status = status_var.get() == "Завершено"
                    
                    # Если статус меняется на "В процессе", проверяем количество накладных у сотрудника
                    if not new_status:
                        # Получаем ID ответственного
                        self.cursor.execute("""
                            SELECT responsible FROM invoice_employee 
                            WHERE invoiceid = %s
                        """, (invoice_id,))
                        employee_id = self.cursor.fetchone()
                        
                        if employee_id:
                            employee_id = employee_id[0]
                            # Проверяем количество активных накладных
                            self.cursor.execute("""
                                SELECT COUNT(*) FROM invoice_employee 
                                WHERE responsible = %s 
                                AND invoiceid IN (SELECT invoice_id FROM invoice WHERE status = FALSE)
                                AND invoiceid != %s
                            """, (employee_id, invoice_id))
                            active_invoices_count = self.cursor.fetchone()[0]
                            
                            if active_invoices_count >= 5:
                                raise ValueError(
                                    f"У сотрудника уже {active_invoices_count} активных накладных. "
                                    "Максимум - 5. Нельзя изменить статус."
                                )
                    
                    self.cursor.execute("""
                        UPDATE invoice SET status = %s WHERE invoice_id = %s
                    """, (new_status, invoice_id))
                    
                    self.conn.commit()
                    self.load_invoices()
                    status_window.destroy()
                    messagebox.showinfo("Успех", "Статус накладной обновлен")
                except ValueError as ve:
                    messagebox.showerror("Ошибка", str(ve))
                except Exception as e:
                    print(f"[UPDATE ERROR] Failed to update invoice status: {e}")
                    self.conn.rollback()
                    messagebox.showerror("Ошибка", f"Не удалось обновить статус: {str(e)}")
            
            Button(status_window, text="Сохранить", command=save_status).pack(pady=10)
            
        except Exception as e:
            print(f"[STATUS UPDATE ERROR] Initial error: {e}")
            messagebox.showerror("Ошибка", f"Ошибка при обновлении статуса: {str(e)}")
    
    # Аналогично модифицируем другие методы создания вкладок:
    def create_warehouse_tab(self):
        """Создание вкладки для работы со складом с учетом прав доступа"""
        tab = Frame(self.notebook)
        self.notebook.add(tab, text="Склад")
        
        # Таблица склада
        columns = ("ID", "Склад", "Комната", "Стеллаж", "Полка", "Деталь", "Вес")
        self.warehouse_tree = ttk.Treeview(tab, columns=columns, show="headings")
        
        for col in columns:
            self.warehouse_tree.heading(col, text=col)
        
        self.warehouse_tree.column("ID", width=50)
        self.warehouse_tree.column("Склад", width=100)
        self.warehouse_tree.column("Комната", width=100)
        self.warehouse_tree.column("Стеллаж", width=100)
        self.warehouse_tree.column("Полка", width=100)
        self.warehouse_tree.column("Деталь", width=200)
        self.warehouse_tree.column("Вес", width=80)
        
        scroll = ttk.Scrollbar(tab, command=self.warehouse_tree.yview)
        scroll.pack(side=RIGHT, fill=Y)
        self.warehouse_tree.configure(yscrollcommand=scroll.set)
        
        self.warehouse_tree.pack(fill=BOTH, expand=True)
        
        # Контекстное меню (исправленная версия)
        menu_items = []
        if self.can_edit_warehouse:
            menu_items.extend([
                ("Добавить деталь", self.add_warehouse_item),
                ("Изменить деталь", self.edit_warehouse_item),
                ("Удалить деталь", self.delete_warehouse_item),
                (None, None)  # разделитель
            ])
        
        # Добавляем пункт поиска для всех пользователей
        menu_items.extend([
            ("Найти деталь", self.search_warehouse_item),
            (None, None),  # разделитель
            ("Обновить список", self.load_warehouse)
        ])
        
        self.warehouse_tree.bind("<Button-3>", lambda e: self.create_context_menu(e, self.warehouse_tree, menu_items))
        self.warehouse_tree.bind("<Delete>", lambda e: self.delete_warehouse_item())
        
        # Загрузка данных
        self.load_warehouse()
    
    def create_counteragent_tab(self):
        """Создание вкладки для работы с контрагентами"""
        tab = Frame(self.notebook)
        self.notebook.add(tab, text="Контрагенты")
        
        # Таблица контрагентов
        self.counteragent_tree = ttk.Treeview(tab, columns=("ID", "Название", "Контакт", "Телефон", "Адрес"), show="headings")
        
        self.counteragent_tree.heading("ID", text="ID")
        self.counteragent_tree.heading("Название", text="Название")
        self.counteragent_tree.heading("Контакт", text="Контактное лицо")
        self.counteragent_tree.heading("Телефон", text="Телефон")
        self.counteragent_tree.heading("Адрес", text="Адрес")
        
        self.counteragent_tree.column("ID", width=50)
        self.counteragent_tree.column("Название", width=200)
        self.counteragent_tree.column("Контакт", width=150)
        self.counteragent_tree.column("Телефон", width=120)
        self.counteragent_tree.column("Адрес", width=250)
        
        scroll = ttk.Scrollbar(tab, command=self.counteragent_tree.yview)
        scroll.pack(side=RIGHT, fill=Y)
        self.counteragent_tree.configure(yscrollcommand=scroll.set)
        
        self.counteragent_tree.pack(fill=BOTH, expand=True)
        
        # Контекстное меню
        menu_items = []
        if self.can_edit_counteragents:
            menu_items.extend([
                ("Добавить контрагента", self.add_counteragent),
                ("Изменить контрагента", self.edit_counteragent),
                ("Удалить контрагента", self.delete_counteragent),
                (None, None)  # разделитель
            ])
        
        # Добавляем пункт поиска для всех пользователей
        menu_items.extend([
            ("Найти контрагента", self.search_counteragent),  # Используем существующий метод
            (None, None),  # разделитель
            ("Обновить список", self.load_counteragents)
        ])
        
        self.counteragent_tree.bind("<Button-3>", lambda e: self.create_context_menu(e, self.counteragent_tree, menu_items))
        self.counteragent_tree.bind("<Delete>", lambda e: self.delete_counteragent())
        
        # Загрузка данных
        self.load_counteragents()
    
    def create_employee_tab(self):
        """Создание вкладки для работы с сотрудниками"""
        tab = Frame(self.notebook)
        self.notebook.add(tab, text="Сотрудники")
        
        # Таблица сотрудников
        self.employee_tree = ttk.Treeview(tab, columns=("ID", "Роль", "Фамилия", "Имя", "Отчество"), show="headings")
        
        self.employee_tree.heading("ID", text="ID")
        self.employee_tree.heading("Роль", text="Роль")
        self.employee_tree.heading("Фамилия", text="Фамилия")
        self.employee_tree.heading("Имя", text="Имя")
        self.employee_tree.heading("Отчество", text="Отчество")
        
        self.employee_tree.column("ID", width=50)
        self.employee_tree.column("Роль", width=150)
        self.employee_tree.column("Фамилия", width=120)
        self.employee_tree.column("Имя", width=120)
        self.employee_tree.column("Отчество", width=120)
        
        scroll = ttk.Scrollbar(tab, command=self.employee_tree.yview)
        scroll.pack(side=RIGHT, fill=Y)
        self.employee_tree.configure(yscrollcommand=scroll.set)
        
        self.employee_tree.pack(fill=BOTH, expand=True)
        
        # Контекстное меню
        menu_items = []
        if self.can_edit_employees:
            menu_items.extend([
                ("Добавить сотрудника", self.add_employee),
                ("Изменить сотрудника", self.edit_employee),
                ("Удалить сотрудника", self.delete_employee),
                (None, None)  # разделитель
            ])
        
        # Добавляем пункт поиска для всех пользователей
        menu_items.extend([
            ("Найти сотрудника", self.search_employee),
            (None, None),  # разделитель
            ("Обновить список", self.load_employees)
        ])
        
        self.employee_tree.bind("<Button-3>", lambda e: self.create_context_menu(e, self.employee_tree, menu_items))
        self.employee_tree.bind("<Delete>", lambda e: self.delete_employee())
    
        # Загрузка данных
        self.load_employees()
    
    # Методы загрузки данных
    def load_invoices(self):
        """Загрузка данных о накладных"""
        try:
            self.invoice_tree.delete(*self.invoice_tree.get_children())
            
            if self.current_search_conditions['invoice']:
                # Если есть активный поиск, загружаем только найденные записи
                conditions = self.current_search_conditions['invoice']['conditions']
                params = self.current_search_conditions['invoice']['params']
                query = """
                    SELECT 
                        invoice_id,
                        counteragent_name,
                        date_time,
                        type_invoice_text,
                        status_text,
                        type_detail,
                        quantity,
                        responsible_last_name || ' ' || 
                        responsible_first_name || ' ' || 
                        COALESCE(responsible_patronymic, '') as responsible
                    FROM invoice_details_view
                    WHERE """ + " AND ".join(conditions) + """
                    ORDER BY invoice_id
                """
                self.cursor.execute(query, params)
            else:
                # Иначе загружаем все данные
                self.cursor.execute("""
                    SELECT 
                        invoice_id,
                        counteragent_name,
                        date_time,
                        type_invoice_text,
                        status_text,
                        type_detail,
                        quantity,
                        responsible_last_name || ' ' || 
                        responsible_first_name || ' ' || 
                        COALESCE(responsible_patronymic, '') as responsible
                    FROM invoice_details_view
                    ORDER BY invoice_id
                """)
            
            for row in self.cursor.fetchall():
                self.invoice_tree.insert("", END, values=row)
            
            count = len(self.invoice_tree.get_children())
            if self.current_search_conditions['invoice']:
                self.status_bar.config(text=f"Найдено накладных: {count}")
            else:
                self.status_bar.config(text=f"Накладные загружены. Всего: {count}")
        except Exception as e:
            print(f"[LOAD ERROR] Failed to load invoices: {e}")
            self.status_bar.config(text=f"Ошибка загрузки накладных: {str(e)}")
            self.conn.rollback()

    def search_invoice(self):
        """Поиск накладных по различным критериям"""
        search_window = Toplevel(self.root)
        search_window.title("Поиск накладных")
        
        # Создаем элементы формы для поиска
        Label(search_window, text="Критерии поиска:").grid(row=0, column=0, columnspan=2, pady=5)
        
        # ID накладной
        Label(search_window, text="ID накладной:").grid(row=1, column=0, padx=5, pady=5, sticky=W)
        id_var = StringVar()
        id_entry = Entry(search_window, textvariable=id_var)
        id_entry.grid(row=1, column=1, padx=5, pady=5, sticky=EW)
        
        # Контрагент
        Label(search_window, text="Контрагент:").grid(row=2, column=0, padx=5, pady=5, sticky=W)
        counteragent_var = StringVar()
        counteragent_entry = Entry(search_window, textvariable=counteragent_var)
        counteragent_entry.grid(row=2, column=1, padx=5, pady=5, sticky=EW)
        
        Label(search_window, text="Дата (ГГГГ-ММ-ДД):").grid(row=3, column=0, padx=5, pady=5, sticky=W)
        date_from_var = StringVar()
        date_from_entry = Entry(search_window, textvariable=date_from_var)
        date_from_entry.grid(row=3, column=1, padx=5, pady=5, sticky=EW)
        
        # Тип накладной
        Label(search_window, text="Тип накладной:").grid(row=5, column=0, padx=5, pady=5, sticky=W)
        type_var = StringVar()
        type_combobox = ttk.Combobox(search_window, textvariable=type_var, 
                                    values=["", "Отгрузка", "Выгрузка"])
        type_combobox.grid(row=5, column=1, padx=5, pady=5, sticky=EW)
        
        # Статус
        Label(search_window, text="Статус:").grid(row=6, column=0, padx=5, pady=5, sticky=W)
        status_var = StringVar()
        status_combobox = ttk.Combobox(search_window, textvariable=status_var, 
                                    values=["", "В процессе", "Завершено"])
        status_combobox.grid(row=6, column=1, padx=5, pady=5, sticky=EW)
        
        # Деталь
        Label(search_window, text="Деталь:").grid(row=7, column=0, padx=5, pady=5, sticky=W)
        detail_var = StringVar()
        detail_entry = Entry(search_window, textvariable=detail_var)
        detail_entry.grid(row=7, column=1, padx=5, pady=5, sticky=EW)
        
        # Ответственный
        Label(search_window, text="Ответственный:").grid(row=8, column=0, padx=5, pady=5, sticky=W)
        responsible_var = StringVar()
        responsible_entry = Entry(search_window, textvariable=responsible_var)
        responsible_entry.grid(row=8, column=1, padx=5, pady=5, sticky=EW)
        
        def perform_search():
            try:
                conditions = []
                params = []
                
                if id_var.get():
                    conditions.append("invoice_id = %s")
                    params.append(int(id_var.get()))
                
                if counteragent_var.get():
                    conditions.append("counteragent_name ILIKE %s")
                    params.append(f"%{counteragent_var.get()}%")
                
                if date_from_var.get():
                    conditions.append("date_time >= %s")
                    params.append(date_from_var.get())
                
                if type_var.get():
                    conditions.append("type_invoice_text = %s")
                    params.append(type_var.get())
                
                if status_var.get():
                    conditions.append("status_text = %s")
                    params.append(status_var.get())
                
                if detail_var.get():
                    conditions.append("type_detail ILIKE %s")
                    params.append(f"%{detail_var.get()}%")
                
                if responsible_var.get():
                    conditions.append("""
                        (responsible_last_name ILIKE %s OR 
                        responsible_first_name ILIKE %s OR 
                        COALESCE(responsible_patronymic, '') ILIKE %s)
                    """)
                    params.extend([
                        f"%{responsible_var.get()}%",
                        f"%{responsible_var.get()}%",
                        f"%{responsible_var.get()}%"
                    ])
                
                # Сохраняем условия поиска
                self.current_search_conditions['invoice'] = {
                    'conditions': conditions,
                    'params': params
                }
                
                # Выполняем поиск и обновляем таблицу
                self.load_invoices()
                search_window.destroy()
                
            except ValueError as ve:
                messagebox.showerror("Ошибка", f"Некорректные данные: {str(ve)}")
            except Exception as e:
                self.status_bar.config(text=f"Ошибка поиска: {str(e)}")
                self.conn.rollback()

        def reset_search():
            self.current_search_conditions['invoice'] = None
            self.load_invoices()
            search_window.destroy()
        
        Button(search_window, text="Найти", command=perform_search).grid(
            row=9, column=0, padx=5, pady=10, sticky=EW)
        Button(search_window, text="Сбросить", command=reset_search).grid(
            row=9, column=1, padx=5, pady=10, sticky=EW)
    
    def load_warehouse(self):
        """Загрузка данных о складе"""
        try:
            self.warehouse_tree.delete(*self.warehouse_tree.get_children())
            
            if self.current_search_conditions['warehouse']:
                conditions = self.current_search_conditions['warehouse']['conditions']
                params = self.current_search_conditions['warehouse']['params']
                query = """
                    SELECT 
                        detail_id,
                        warehouse_number,
                        room_number,
                        rack_number,
                        shelf_number,
                        type_detail,
                        weight
                    FROM warehouse_details_view
                    WHERE """ + " AND ".join(conditions) + """
                    ORDER BY detail_id, warehouse_number, room_number, rack_number, shelf_number
                """
                self.cursor.execute(query, params)
            else:
                self.cursor.execute("""
                    SELECT 
                        detail_id,
                        warehouse_number,
                        room_number,
                        rack_number,
                        shelf_number,
                        type_detail,
                        weight
                    FROM warehouse_details_view
                    ORDER BY detail_id, warehouse_number, room_number, rack_number, shelf_number
                """)
            
            for row in self.cursor.fetchall():
                self.warehouse_tree.insert("", END, values=row)
            
            count = len(self.warehouse_tree.get_children())
            if self.current_search_conditions['warehouse']:
                self.status_bar.config(text=f"Найдено деталей: {count}")
            else:
                self.status_bar.config(text=f"Данные склада загружены. Всего: {count}")
        except Exception as e:
            print(f"[LOAD ERROR] Failed to load warehouse data: {e}")
            self.status_bar.config(text=f"Ошибка загрузки данных склада: {str(e)}")
            self.conn.rollback()

    def search_warehouse_item(self):
        """Поиск деталей на складе по различным критериям"""
        search_window = Toplevel(self.root)
        search_window.title("Поиск деталей на складе")
        
        # Создаем элементы формы для поиска
        Label(search_window, text="Критерии поиска:").grid(row=0, column=0, columnspan=2, pady=5)
        
        # Тип детали
        Label(search_window, text="Тип детали:").grid(row=1, column=0, padx=5, pady=5, sticky=W)
        type_var = StringVar()
        type_entry = Entry(search_window, textvariable=type_var)
        type_entry.grid(row=1, column=1, padx=5, pady=5, sticky=EW)
        
        # Номер склада
        Label(search_window, text="Номер склада:").grid(row=2, column=0, padx=5, pady=5, sticky=W)
        warehouse_var = StringVar()
        warehouse_entry = Entry(search_window, textvariable=warehouse_var)
        warehouse_entry.grid(row=2, column=1, padx=5, pady=5, sticky=EW)
        
        # Номер комнаты
        Label(search_window, text="Номер комнаты:").grid(row=3, column=0, padx=5, pady=5, sticky=W)
        room_var = StringVar()
        room_entry = Entry(search_window, textvariable=room_var)
        room_entry.grid(row=3, column=1, padx=5, pady=5, sticky=EW)
        
        # Номер стеллажа
        Label(search_window, text="Номер стеллажа:").grid(row=4, column=0, padx=5, pady=5, sticky=W)
        rack_var = StringVar()
        rack_entry = Entry(search_window, textvariable=rack_var)
        rack_entry.grid(row=4, column=1, padx=5, pady=5, sticky=EW)
        
        # Номер полки
        Label(search_window, text="Номер полки:").grid(row=5, column=0, padx=5, pady=5, sticky=W)
        shelf_var = StringVar()
        shelf_entry = Entry(search_window, textvariable=shelf_var)
        shelf_entry.grid(row=5, column=1, padx=5, pady=5, sticky=EW)
        
        # Вес (от и до)
        Label(search_window, text="Вес от:").grid(row=6, column=0, padx=5, pady=5, sticky=W)
        weight_from_var = StringVar()
        weight_from_entry = Entry(search_window, textvariable=weight_from_var)
        weight_from_entry.grid(row=6, column=1, padx=5, pady=5, sticky=EW)
        
        Label(search_window, text="Вес до:").grid(row=7, column=0, padx=5, pady=5, sticky=W)
        weight_to_var = StringVar()
        weight_to_entry = Entry(search_window, textvariable=weight_to_var)
        weight_to_entry.grid(row=7, column=1, padx=5, pady=5, sticky=EW)
        
        def perform_search():
            try:
                conditions = []
                params = []
                
                if type_var.get():
                    conditions.append("type_detail ILIKE %s")
                    params.append(f"%{type_var.get()}%")
                
                if warehouse_var.get():
                    conditions.append("warehouse_number = %s")
                    params.append(warehouse_var.get())
                
                if room_var.get():
                    conditions.append("room_number = %s")
                    params.append(room_var.get())
                
                if rack_var.get():
                    conditions.append("rack_number = %s")
                    params.append(rack_var.get())
                
                if shelf_var.get():
                    conditions.append("shelf_number = %s")
                    params.append(shelf_var.get())
                
                if weight_from_var.get():
                    try:
                        weight_from = float(weight_from_var.get())
                        conditions.append("weight >= %s")
                        params.append(weight_from)
                    except ValueError:
                        messagebox.showwarning("Предупреждение", "Некорректное значение веса 'от'")
                
                if weight_to_var.get():
                    try:
                        weight_to = float(weight_to_var.get())
                        conditions.append("weight <= %s")
                        params.append(weight_to)
                    except ValueError:
                        messagebox.showwarning("Предупреждение", "Некорректное значение веса 'до'")
                
                # Сохраняем условия поиска
                self.current_search_conditions['warehouse'] = {
                    'conditions': conditions,
                    'params': params
                }
                
                # Выполняем поиск и обновляем таблицу
                self.load_warehouse()
                search_window.destroy()
                
            except Exception as e:
                self.status_bar.config(text=f"Ошибка поиска: {str(e)}")
                self.conn.rollback()

        def reset_search():
            self.current_search_conditions['warehouse'] = None
            self.load_warehouse()
            search_window.destroy()
        
        Button(search_window, text="Найти", command=perform_search).grid(
            row=8, column=0, padx=5, pady=10, sticky=EW)
        Button(search_window, text="Сбросить", command=reset_search).grid(
            row=8, column=1, padx=5, pady=10, sticky=EW)
            
    
    def load_counteragents(self):
        """Загрузка данных о контрагентах"""
        try:
            self.counteragent_tree.delete(*self.counteragent_tree.get_children())
            
            if self.current_search_conditions['counteragent']:
                conditions = self.current_search_conditions['counteragent']['conditions']
                params = self.current_search_conditions['counteragent']['params']
                query = "SELECT * FROM counteragent WHERE " + " AND ".join(conditions) + " ORDER BY counteragent_id"
                self.cursor.execute(query, params)
            else:
                self.cursor.execute("SELECT * FROM counteragent ORDER BY counteragent_id")
            
            for row in self.cursor.fetchall():
                self.counteragent_tree.insert("", END, values=row)
            
            count = len(self.counteragent_tree.get_children())
            if self.current_search_conditions['counteragent']:
                self.status_bar.config(text=f"Найдено контрагентов: {count}")
            else:
                self.status_bar.config(text=f"Контрагенты загружены. Всего: {count}")
        except Exception as e:
            self.status_bar.config(text=f"Ошибка: {str(e)}")

    def search_counteragent(self):
        """Поиск контрагентов по различным критериям"""
        search_window = Toplevel(self.root)
        search_window.title("Поиск контрагентов")
        
        # Создаем элементы формы для поиска
        Label(search_window, text="Критерии поиска:").grid(row=0, column=0, columnspan=2, pady=5)
        
        # ID контрагента
        Label(search_window, text="ID контрагента:").grid(row=1, column=0, padx=5, pady=5, sticky=W)
        id_var = StringVar()
        id_entry = Entry(search_window, textvariable=id_var)
        id_entry.grid(row=1, column=1, padx=5, pady=5, sticky=EW)
        
        # Название контрагента
        Label(search_window, text="Название:").grid(row=2, column=0, padx=5, pady=5, sticky=W)
        name_var = StringVar()
        name_entry = Entry(search_window, textvariable=name_var)
        name_entry.grid(row=2, column=1, padx=5, pady=5, sticky=EW)
        
        # Контактное лицо
        Label(search_window, text="Контактное лицо:").grid(row=3, column=0, padx=5, pady=5, sticky=W)
        contact_var = StringVar()
        contact_entry = Entry(search_window, textvariable=contact_var)
        contact_entry.grid(row=3, column=1, padx=5, pady=5, sticky=EW)
        
        # Телефон
        Label(search_window, text="Телефон:").grid(row=4, column=0, padx=5, pady=5, sticky=W)
        phone_var = StringVar()
        phone_entry = Entry(search_window, textvariable=phone_var)
        phone_entry.grid(row=4, column=1, padx=5, pady=5, sticky=EW)
        
        # Адрес
        Label(search_window, text="Адрес:").grid(row=5, column=0, padx=5, pady=5, sticky=W)
        address_var = StringVar()
        address_entry = Entry(search_window, textvariable=address_var)
        address_entry.grid(row=5, column=1, padx=5, pady=5, sticky=EW)
        
        def perform_search():
            try:
                conditions = []
                params = []
                
                if id_var.get():
                    conditions.append("counteragent_id = %s")
                    params.append(int(id_var.get()))
                
                if name_var.get():
                    conditions.append("counteragent_name ILIKE %s")
                    params.append(f"%{name_var.get()}%")
                
                if contact_var.get():
                    conditions.append("contact_person ILIKE %s")
                    params.append(f"%{contact_var.get()}%")
                
                if phone_var.get():
                    conditions.append("phone_number::text LIKE %s")
                    params.append(f"%{phone_var.get()}%")
                
                if address_var.get():
                    conditions.append("address ILIKE %s")
                    params.append(f"%{address_var.get()}%")
                
                # Сохраняем условия поиска
                self.current_search_conditions['counteragent'] = {
                    'conditions': conditions,
                    'params': params
                }
                
                # Выполняем поиск и обновляем таблицу
                self.load_counteragents()
                search_window.destroy()
                
            except ValueError as ve:
                messagebox.showerror("Ошибка", f"Некорректные данные: {str(ve)}")
            except Exception as e:
                self.status_bar.config(text=f"Ошибка поиска: {str(e)}")
                self.conn.rollback()

        def reset_search():
            self.current_search_conditions['counteragent'] = None
            self.load_counteragents()
            search_window.destroy()
        
        Button(search_window, text="Найти", command=perform_search).grid(
            row=6, column=0, padx=5, pady=10, sticky=EW)
        Button(search_window, text="Сбросить", command=reset_search).grid(
            row=6, column=1, padx=5, pady=10, sticky=EW)
    
    def load_employees(self):
        """Загрузка данных о сотрудниках"""
        try:
            self.employee_tree.delete(*self.employee_tree.get_children())
            
            if self.current_search_conditions['employee']:
                conditions = self.current_search_conditions['employee']['conditions']
                params = self.current_search_conditions['employee']['params']
                query = "SELECT * FROM employee WHERE " + " AND ".join(conditions) + " ORDER BY employee_id"
                self.cursor.execute(query, params)
            else:
                self.cursor.execute("SELECT * FROM employee ORDER BY employee_id")
            
            for row in self.cursor.fetchall():
                self.employee_tree.insert("", END, values=row)
            
            count = len(self.employee_tree.get_children())
            if self.current_search_conditions['employee']:
                self.status_bar.config(text=f"Найдено сотрудников: {count}")
            else:
                self.status_bar.config(text=f"Сотрудники загружены. Всего: {count}")
        except Exception as e:
            self.status_bar.config(text=f"Ошибка: {str(e)}")

    def search_employee(self):
        """Поиск сотрудников по различным критериям"""
        search_window = Toplevel(self.root)
        search_window.title("Поиск сотрудников")
        
        # Создаем элементы формы для поиска
        Label(search_window, text="Критерии поиска:").grid(row=0, column=0, columnspan=2, pady=5)
        
        # ID сотрудника
        Label(search_window, text="ID сотрудника:").grid(row=1, column=0, padx=5, pady=5, sticky=W)
        id_var = StringVar()
        id_entry = Entry(search_window, textvariable=id_var)
        id_entry.grid(row=1, column=1, padx=5, pady=5, sticky=EW)
        
        # Роль
        Label(search_window, text="Роль:").grid(row=2, column=0, padx=5, pady=5, sticky=W)
        role_var = StringVar()
        role_combobox = ttk.Combobox(search_window, textvariable=role_var, 
                                    values=["", "Кладовщик", "Менеджер склада", "Владелец"])
        role_combobox.grid(row=2, column=1, padx=5, pady=5, sticky=EW)
        
        # Фамилия
        Label(search_window, text="Фамилия:").grid(row=3, column=0, padx=5, pady=5, sticky=W)
        last_name_var = StringVar()
        last_name_entry = Entry(search_window, textvariable=last_name_var)
        last_name_entry.grid(row=3, column=1, padx=5, pady=5, sticky=EW)
        
        # Имя
        Label(search_window, text="Имя:").grid(row=4, column=0, padx=5, pady=5, sticky=W)
        first_name_var = StringVar()
        first_name_entry = Entry(search_window, textvariable=first_name_var)
        first_name_entry.grid(row=4, column=1, padx=5, pady=5, sticky=EW)
        
        # Отчество
        Label(search_window, text="Отчество:").grid(row=5, column=0, padx=5, pady=5, sticky=W)
        patronymic_var = StringVar()
        patronymic_entry = Entry(search_window, textvariable=patronymic_var)
        patronymic_entry.grid(row=5, column=1, padx=5, pady=5, sticky=EW)
        
        def perform_search():
            try:
                conditions = []
                params = []
                
                if id_var.get():
                    conditions.append("employee_id = %s")
                    params.append(int(id_var.get()))
                
                if role_var.get():
                    conditions.append("employee_role = %s")
                    params.append(role_var.get())
                
                if last_name_var.get():
                    conditions.append("last_name ILIKE %s")
                    params.append(f"%{last_name_var.get()}%")
                
                if first_name_var.get():
                    conditions.append("first_name ILIKE %s")
                    params.append(f"%{first_name_var.get()}%")
                
                if patronymic_var.get():
                    conditions.append("patronymic ILIKE %s")
                    params.append(f"%{patronymic_var.get()}%")
                
                # Сохраняем условия поиска
                self.current_search_conditions['employee'] = {
                    'conditions': conditions,
                    'params': params
                }
                
                # Выполняем поиск и обновляем таблицу
                self.load_employees()
                search_window.destroy()
                
            except ValueError as ve:
                messagebox.showerror("Ошибка", f"Некорректные данные: {str(ve)}")
            except Exception as e:
                self.status_bar.config(text=f"Ошибка поиска: {str(e)}")
                self.conn.rollback()

        def reset_search():
            self.current_search_conditions['employee'] = None
            self.load_employees()
            search_window.destroy()
        
        Button(search_window, text="Найти", command=perform_search).grid(
            row=6, column=0, padx=5, pady=10, sticky=EW)
        Button(search_window, text="Сбросить", command=reset_search).grid(
            row=6, column=1, padx=5, pady=10, sticky=EW)
    
    # Методы для работы с накладными
    def add_invoice(self):
        """Добавление новой накладной с проверкой прав"""
        if not self.can_edit_invoices:
            messagebox.showerror("Ошибка", "У вас нет прав на добавление накладных")
            return
        
        try:
            add_window = Toplevel(self.root)
            add_window.title("Добавить накладную")
            
            # Получаем список контрагентов (если есть доступ)
            if self.can_access_counteragents:
                self.cursor.execute("SELECT counteragent_id, counteragent_name FROM counteragent")
                counteragents = self.cursor.fetchall()
                counteragent_names = [name for id, name in counteragents]
                counteragent_ids = {name: id for id, name in counteragents}
            else:
                counteragents = []
                counteragent_names = []
                counteragent_ids = {}
                messagebox.showwarning("Предупреждение", "Нет доступа к списку контрагентов")
            
            # Получаем список ответственных ИЗ ПРЕДСТАВЛЕНИЯ (без доступа к таблице employee)
            self.cursor.execute("""
                SELECT DISTINCT 
                    responsible_id,
                    responsible_last_name || ' ' || 
                    responsible_first_name || ' ' || 
                    COALESCE(responsible_patronymic, '') as responsible_name
                FROM invoice_details_view
                ORDER BY responsible_name
            """)
            employees = self.cursor.fetchall()
            employee_names = [name for id, name in employees]
            employee_ids = {name: id for id, name in employees}
            
            # Создаем элементы формы
            Label(add_window, text="Контрагент:").grid(row=0, column=0, padx=5, pady=5, sticky=W)
            counteragent_var = StringVar()
            counteragent_combobox = ttk.Combobox(add_window, textvariable=counteragent_var, values=counteragent_names)
            counteragent_combobox.grid(row=0, column=1, padx=5, pady=5, sticky=EW)
            
            Label(add_window, text="Дата и время (ГГГГ-ММ-ДД ЧЧ:ММ):").grid(row=1, column=0, padx=5, pady=5, sticky=W)
            date_entry = Entry(add_window)
            # Устанавливаем текущую дату и время по умолчанию
            current_datetime = datetime.now().strftime("%Y-%m-%d %H:%M")
            date_entry.insert(0, current_datetime)
            date_entry.grid(row=1, column=1, padx=5, pady=5, sticky=EW)
            
            Label(add_window, text="Тип накладной:").grid(row=2, column=0, padx=5, pady=5, sticky=W)
            type_var = StringVar()
            type_combobox = ttk.Combobox(add_window, textvariable=type_var, values=["Отгрузка", "Выгрузка"])
            type_combobox.current(0)
            type_combobox.grid(row=2, column=1, padx=5, pady=5, sticky=EW)
            
            Label(add_window, text="Статус:").grid(row=3, column=0, padx=5, pady=5, sticky=W)
            status_var = StringVar()
            status_combobox = ttk.Combobox(add_window, textvariable=status_var, values=["В процессе", "Завершено"])
            status_combobox.current(0)
            status_combobox.grid(row=3, column=1, padx=5, pady=5, sticky=EW)
            
            # Изменено: поле ввода вместо выпадающего списка
            Label(add_window, text="Деталь:").grid(row=4, column=0, padx=5, pady=5, sticky=W)
            detail_var = StringVar()
            detail_entry = Entry(add_window, textvariable=detail_var)
            detail_entry.grid(row=4, column=1, padx=5, pady=5, sticky=EW)
            
            Label(add_window, text="Количество:").grid(row=5, column=0, padx=5, pady=5, sticky=W)
            quantity_entry = Entry(add_window)
            quantity_entry.grid(row=5, column=1, padx=5, pady=5, sticky=EW)
            
            Label(add_window, text="Ответственный:").grid(row=6, column=0, padx=5, pady=5, sticky=W)
            employee_var = StringVar()
            employee_combobox = ttk.Combobox(add_window, textvariable=employee_var, values=employee_names)
            employee_combobox.grid(row=6, column=1, padx=5, pady=5, sticky=EW)
            
            def save_invoice():
                try:
                    # Проверяем дату
                    input_datetime_str = date_entry.get()
                    try:
                        input_datetime = datetime.strptime(input_datetime_str, "%Y-%m-%d %H:%M")
                    except ValueError:
                        raise ValueError("Некорректный формат даты. Используйте ГГГГ-ММ-ДД ЧЧ:ММ")
                    
                    current_datetime = datetime.now()
                    if input_datetime > current_datetime:
                        raise ValueError("Дата накладной не может быть в будущем. Укажите текущую или прошедшую дату.")
                    
                    # Получаем ID из выбранных значений через словари
                    counteragent_id = counteragent_ids.get(counteragent_var.get())
                    employee_id = employee_ids.get(employee_var.get())

                    # Проверка количества накладных у сотрудника (новый код)
                    if employee_id:
                        self.cursor.execute("""
                            SELECT COUNT(*) FROM invoice_employee 
                            WHERE responsible = %s AND invoiceid IN (
                                SELECT invoice_id FROM invoice WHERE status = FALSE
                            )
                        """, (employee_id,))
                        active_invoices_count = self.cursor.fetchone()[0]
                        
                        if active_invoices_count >= 5:
                            raise ValueError(f"У сотрудника уже {active_invoices_count} активных накладных. Максимум - 5.")
                    
                    if None in (counteragent_id, employee_id):
                        raise ValueError("Не все обязательные поля заполнены")
                    
                    # Проверяем существование детали
                    detail_name = detail_var.get().strip()
                    if not detail_name:
                        raise ValueError("Название детали не может быть пустым")
                    
                    # Получаем ID и тип детали
                    self.cursor.execute("""
                        SELECT detail_id FROM details 
                        WHERE type_detail = %s
                        LIMIT 1
                    """, (detail_name,))
                    
                    detail_data = self.cursor.fetchone()
                    if not detail_data:
                        raise ValueError(f"Деталь '{detail_name}' не найдена на складе")
                    
                    detail_id = detail_data[0]
                    
                    # Преобразуем тип и статус
                    type_invoice = type_var.get() == "Выгрузка"  # True - выгрузка, False - отгрузка
                    status = status_var.get() == "Завершено"
                    
                    # Получаем количество
                    try:
                        quantity = int(quantity_entry.get())
                        if quantity <= 0:
                            raise ValueError("Количество должно быть положительным числом")
                    except ValueError:
                        raise ValueError("Количество должно быть целым числом")
                    
                    # Проверка доступности деталей
                    if not type_invoice:  # Только для отгрузки (не для выгрузки)
                        # 1. Получаем общее количество деталей этого типа на складе
                        self.cursor.execute("""
                            SELECT COUNT(*) 
                            FROM details 
                            WHERE type_detail = %s
                        """, (detail_name,))
                        total_available = self.cursor.fetchone()[0]
                        
                        # 2. Получаем сумму всех запланированных к отгрузке деталей ЭТОГО ТИПА
                        self.cursor.execute("""
                            SELECT COALESCE(SUM(id.quantity), 0)
                            FROM invoice_detail id
                            JOIN invoice i ON id.invoiceid = i.invoice_id
                            JOIN details d ON id.detailid = d.detail_id
                            WHERE d.type_detail = %s AND i.type_invoice = FALSE AND i.status = FALSE
                        """, (detail_name,))
                        reserved = self.cursor.fetchone()[0]
                        
                        # 3. Проверяем доступность
                        if total_available < (reserved + quantity):
                            raise ValueError(
                                f"Недостаточно деталей на складе для отгрузки. Доступно: {total_available}, "
                                f"уже зарезервировано для отгрузки: {reserved}, требуется: {quantity}"
                            )
                    # ===== КОНЕЦ НОВОГО КОДА =====
                    
                    # Вставляем накладную
                    self.cursor.execute("""
                        INSERT INTO invoice (counteragentid, date_time, type_invoice, status)
                        VALUES (%s, %s, %s, %s)
                        RETURNING invoice_id
                    """, (counteragent_id, input_datetime_str, type_invoice, status))
                    
                    invoice_id = self.cursor.fetchone()[0]
                    
                    # Добавляем деталь в накладную
                    self.cursor.execute("""
                        INSERT INTO invoice_detail (invoiceid, detailid, quantity)
                        VALUES (%s, %s, %s)
                    """, (invoice_id, detail_id, quantity))
                    
                    # Назначаем ответственного
                    self.cursor.execute("""
                        INSERT INTO invoice_employee (invoiceid, responsible, granted_access, when_granted)
                        VALUES (%s, %s, %s, NOW())
                    """, (invoice_id, employee_id, employee_id))
                    
                    self.conn.commit()
                    self.load_invoices()
                    add_window.destroy()
                    messagebox.showinfo("Успех", "Накладная успешно добавлена")
                except ValueError as ve:
                    messagebox.showerror("Ошибка", f"Неверные данные: {str(ve)}")
                except Exception as e:
                    self.conn.rollback()
                    messagebox.showerror("Ошибка", f"Не удалось добавить накладную: {str(e)}")
            
            Button(add_window, text="Сохранить", command=save_invoice).grid(row=7, column=0, columnspan=2, pady=10)
            
        except Exception as e:
            messagebox.showerror("Ошибка", f"Не удалось открыть форму: {str(e)}")

    def edit_invoice(self):
        """Редактирование накладной с проверкой прав"""
        if not self.can_edit_invoices:
            messagebox.showerror("Ошибка", "У вас нет прав на редактирование накладных")
            return
        
        selected = self.invoice_tree.selection()
        if not selected:
            messagebox.showwarning("Предупреждение", "Выберите накладную для редактирования")
            return
        
        item = self.invoice_tree.item(selected[0])
        invoice_id = item['values'][0]
        
        try:
            # Получаем данные о накладной
            self.cursor.execute("""
                SELECT 
                    invoice_id,
                    counteragent_name,
                    date_time,
                    type_invoice_text,
                    status_text,
                    type_detail,
                    quantity,
                    responsible_last_name || ' ' || 
                    responsible_first_name || ' ' || 
                    COALESCE(responsible_patronymic, '') as responsible
                FROM invoice_details_view
                WHERE invoice_id = %s
            """, (invoice_id,))
            
            invoice_data = self.cursor.fetchone()
            
            if not invoice_data:
                messagebox.showerror("Ошибка", "Накладная не найдена")
                return
            
            edit_window = Toplevel(self.root)
            edit_window.title("Редактировать накладную")
            
            # Получаем списки для выпадающих списков
            self.cursor.execute("SELECT counteragent_id, counteragent_name FROM counteragent")
            counteragents = self.cursor.fetchall()
            counteragent_names = [f"{id}: {name}" for id, name in counteragents]
            
            self.cursor.execute("""
                SELECT DISTINCT 
                    responsible_id,
                    responsible_last_name || ' ' || 
                    responsible_first_name || ' ' || 
                    COALESCE(responsible_patronymic, '') as responsible_name
                FROM invoice_details_view
                ORDER BY responsible_name
            """)
            employees = self.cursor.fetchall()
            employee_names = [name for id, name in employees]
            employee_ids = {name: id for id, name in employees}
            
            # Создаем элементы формы с текущими значениями
            Label(edit_window, text="Контрагент:").grid(row=0, column=0, padx=5, pady=5, sticky=W)
            counteragent_var = StringVar()
            counteragent_combobox = ttk.Combobox(edit_window, textvariable=counteragent_var, values=counteragent_names)
            counteragent_combobox.grid(row=0, column=1, padx=5, pady=5, sticky=EW)
            
            # Устанавливаем текущее значение контрагента
            for id, name in counteragents:
                if name == invoice_data[1]:  # invoice_data[1] — это counteragent_name
                    counteragent_var.set(f"{id}: {name}")
                    break
            
            Label(edit_window, text="Дата и время:").grid(row=1, column=0, padx=5, pady=5, sticky=W)
            date_entry = Entry(edit_window)
            date_entry.insert(0, invoice_data[2].strftime("%Y-%m-%d %H:%M"))
            date_entry.grid(row=1, column=1, padx=5, pady=5, sticky=EW)
            
            Label(edit_window, text="Тип накладной:").grid(row=2, column=0, padx=5, pady=5, sticky=W)
            type_var = StringVar()
            type_combobox = ttk.Combobox(edit_window, textvariable=type_var, values=["Отгрузка", "Выгрузка"])
            type_combobox.current(1 if invoice_data[3] == "Выгрузка" else 0)
            type_combobox.grid(row=2, column=1, padx=5, pady=5, sticky=EW)
            
            Label(edit_window, text="Статус:").grid(row=3, column=0, padx=5, pady=5, sticky=W)
            status_var = StringVar()
            status_combobox = ttk.Combobox(edit_window, textvariable=status_var, values=["В процессе", "Завершено"])
            status_combobox.current(1 if invoice_data[4] == "Завершено" else 0)
            status_combobox.grid(row=3, column=1, padx=5, pady=5, sticky=EW)
            
            # Заменяем Combobox на Entry для типа детали
            Label(edit_window, text="Тип детали:").grid(row=4, column=0, padx=5, pady=5, sticky=W)
            detail_var = StringVar(value=invoice_data[5])  # invoice_data[5] — это type_detail
            detail_entry = Entry(edit_window, textvariable=detail_var)
            detail_entry.grid(row=4, column=1, padx=5, pady=5, sticky=EW)
            
            Label(edit_window, text="Количество:").grid(row=5, column=0, padx=5, pady=5, sticky=W)
            quantity_entry = Entry(edit_window)
            quantity_entry.insert(0, str(invoice_data[6]))  # invoice_data[6] — это quantity
            quantity_entry.grid(row=5, column=1, padx=5, pady=5, sticky=EW)
            
            Label(edit_window, text="Ответственный:").grid(row=6, column=0, padx=5, pady=5, sticky=W)
            employee_var = StringVar()
            employee_combobox = ttk.Combobox(edit_window, textvariable=employee_var, values=employee_names)
            employee_combobox.grid(row=6, column=1, padx=5, pady=5, sticky=EW)
            
            # Устанавливаем текущее значение сотрудника
            for id, name in employees:
                if name == invoice_data[7]:  # invoice_data[7] — это ответственный
                    employee_var.set(name)
                    break
            
            def save_changes():
                try:
                    # Проверяем, что тип детали существует в БД
                    detail_name = detail_var.get().strip()
                    if not detail_name:
                        raise ValueError("Тип детали не может быть пустым")
                    
                    self.cursor.execute("""
                        SELECT detail_id FROM details 
                        WHERE type_detail = %s
                        LIMIT 1
                    """, (detail_name,))
                    
                    detail_data = self.cursor.fetchone()
                    if not detail_data:
                        raise ValueError(f"Деталь '{detail_name}' не найдена на складе")
                    
                    detail_id = detail_data[0]
                    
                    # Проверяем количество (должно быть > 0)
                    try:
                        quantity = int(quantity_entry.get())
                        if quantity <= 0:
                            raise ValueError("Количество должно быть положительным числом!")
                    except ValueError:
                        raise ValueError("Количество должно быть целым числом!")
                    
                    # Получаем ID из выбранных значений
                    counteragent_id = int(counteragent_var.get().split(":")[0])
                    employee_id = employee_ids.get(employee_var.get())
                    
                    # Проверка количества накладных у сотрудника (НОВЫЙ КОД)
                    if employee_id:
                        self.cursor.execute("""
                            SELECT COUNT(*) FROM invoice_employee 
                            WHERE responsible = %s 
                            AND invoiceid IN (SELECT invoice_id FROM invoice WHERE status = FALSE)
                            AND invoiceid != %s
                        """, (employee_id, invoice_id))
                        active_invoices_count = self.cursor.fetchone()[0]
                        
                        if active_invoices_count >= 5:
                            raise ValueError(f"У сотрудника уже {active_invoices_count} активных накладных. Максимум - 5.")
                    
                    # Преобразуем тип и статус
                    type_invoice = type_var.get() == "Выгрузка"
                    status = status_var.get() == "Завершено"
                    
                    # Проверка доступности деталей
                    if not type_invoice:  # Если это отгрузка
                        # 1. Получаем текущее количество в этой накладной (если было)
                        self.cursor.execute("""
                            SELECT quantity FROM invoice_detail 
                            WHERE invoiceid = %s
                        """, (invoice_id,))
                        old_quantity_row = self.cursor.fetchone()
                        old_quantity = old_quantity_row[0] if old_quantity_row else 0
                        
                        # 2. Получаем ФАКТИЧЕСКОЕ количество деталей этого типа на складе
                        self.cursor.execute("""
                            SELECT COUNT(*) 
                            FROM details d
                            WHERE d.type_detail = %s
                            AND NOT EXISTS (
                                SELECT 1 FROM invoice_detail id
                                JOIN invoice i ON id.invoiceid = i.invoice_id
                                WHERE id.detailid = d.detail_id 
                                AND i.type_invoice = FALSE  --- отгрузка
                                AND i.status = TRUE  --- завершённые
                            )
                        """, (detail_name,))
                        total_available = self.cursor.fetchone()[0]
                        
                        # 3. Получаем сумму всех НЕЗАВЕРШЁННЫХ отгрузок этого типа
                        self.cursor.execute("""
                            SELECT COALESCE(SUM(id.quantity), 0)
                            FROM invoice_detail id
                            JOIN invoice i ON id.invoiceid = i.invoice_id
                            JOIN details d ON id.detailid = d.detail_id
                            WHERE d.type_detail = %s 
                            AND i.type_invoice = FALSE  --- отгрузка
                            AND i.status = FALSE  --- в процессе
                            AND i.invoice_id != %s
                        """, (detail_name, invoice_id))
                        reserved = self.cursor.fetchone()[0]
                        
                        # 4. Проверяем доступность с учётом изменений
                        if total_available < (reserved + quantity - old_quantity):
                            raise ValueError(
                                f"Недостаточно деталей на складе для отгрузки. "
                                f"Доступно: {total_available}, "
                                f"уже зарезервировано в других накладных: {reserved}, "
                                f"новое количество: {quantity} (было: {old_quantity})"
                            )
                    
                    # Обновляем накладную
                    self.cursor.execute("""
                        UPDATE invoice 
                        SET counteragentid = %s, date_time = %s, type_invoice = %s, status = %s
                        WHERE invoice_id = %s
                    """, (counteragent_id, date_entry.get(), type_invoice, status, invoice_id))
                    
                    # Обновляем деталь в накладной
                    self.cursor.execute("""
                        UPDATE invoice_detail 
                        SET detailid = %s, quantity = %s
                        WHERE invoiceid = %s
                    """, (detail_id, quantity, invoice_id))
                    
                    # Обновляем ответственного
                    self.cursor.execute("""
                        UPDATE invoice_employee 
                        SET responsible = %s
                        WHERE invoiceid = %s
                    """, (employee_id, invoice_id))
                    
                    self.conn.commit()
                    self.load_invoices()
                    edit_window.destroy()
                    messagebox.showinfo("Успех", "Накладная успешно обновлена")
                except ValueError as ve:
                    messagebox.showerror("Ошибка", f"Неверные данные: {str(ve)}")
                except Exception as e:
                    self.conn.rollback()
                    messagebox.showerror("Ошибка", f"Не удалось обновить накладную: {str(e)}")
            
            Button(edit_window, text="Сохранить", command=save_changes).grid(row=7, column=0, columnspan=2, pady=10)
            
        except Exception as e:
            messagebox.showerror("Ошибка", f"Не удалось открыть форму: {str(e)}")
    
    def delete_invoice(self):
        """Удаление накладной с предварительным удалением связанных записей"""
        selected = self.invoice_tree.selection()
        if not selected:
            messagebox.showwarning("Предупреждение", "Выберите накладную для удаления")
            return
        
        item = self.invoice_tree.item(selected[0])
        invoice_id = item['values'][0]
        
        if messagebox.askyesno("Подтверждение", f"Вы уверены, что хотите удалить накладную №{invoice_id}?"):
            try:
                # 1. Удаляем записи из invoice_detail (связанные детали)
                self.cursor.execute("DELETE FROM invoice_detail WHERE invoiceid = %s", (invoice_id,))
                
                # 2. Удаляем записи из invoice_employee (связанных сотрудников)
                self.cursor.execute("DELETE FROM invoice_employee WHERE invoiceid = %s", (invoice_id,))
                
                # 3. Теперь удаляем саму накладную
                self.cursor.execute("DELETE FROM invoice WHERE invoice_id = %s", (invoice_id,))
                
                self.conn.commit()
                self.load_invoices()
                
                # Проверяем, стала ли таблица пустой после удаления
                if len(self.invoice_tree.get_children()) == 0 and self.current_search_conditions['invoice']:
                    messagebox.showinfo("Информация", "Таблица пуста. Сброс условий поиска.")
                    self.current_search_conditions['invoice'] = None
                    self.load_invoices()
                    
                messagebox.showinfo("Успех", "Накладная успешно удалена")
            except Exception as e:
                self.conn.rollback()
                messagebox.showerror("Ошибка", f"Не удалось удалить накладную: {str(e)}")
    
    # Методы для работы со складом
    def add_warehouse_item(self):
        """Добавление детали на склад с динамическими выпадающими списками"""
        if not self.can_edit_warehouse:
            messagebox.showerror("Ошибка", "У вас нет прав на добавление деталей")
            return

        try:
            add_window = Toplevel(self.root)
            add_window.title("Добавить деталь на склад")
            
            # Получаем список складов
            self.cursor.execute("SELECT warehouse_id, warehouse_number FROM warehouse ORDER BY warehouse_number")
            warehouses = self.cursor.fetchall()
            warehouse_options = [str(number) for id, number in warehouses]
            warehouse_ids = {str(number): id for id, number in warehouses}

            # Создаем элементы формы
            row = 0
            
            # Склад (выпадающий список)
            Label(add_window, text="Номер склада:").grid(row=row, column=0, padx=5, pady=5, sticky=W)
            warehouse_var = StringVar()
            warehouse_combobox = ttk.Combobox(add_window, textvariable=warehouse_var, 
                                            values=warehouse_options, state="readonly")
            warehouse_combobox.grid(row=row, column=1, padx=5, pady=5, sticky=EW)
            row += 1

            # Комната (выпадающий список)
            Label(add_window, text="Номер комнаты:").grid(row=row, column=0, padx=5, pady=5, sticky=W)
            room_var = StringVar()
            room_combobox = ttk.Combobox(add_window, textvariable=room_var, 
                                        values=[], state="readonly")
            room_combobox.grid(row=row, column=1, padx=5, pady=5, sticky=EW)
            row += 1

            # Стеллаж (выпадающий список)
            Label(add_window, text="Номер стеллажа:").grid(row=row, column=0, padx=5, pady=5, sticky=W)
            rack_var = StringVar()
            rack_combobox = ttk.Combobox(add_window, textvariable=rack_var, 
                                        values=[], state="readonly")
            rack_combobox.grid(row=row, column=1, padx=5, pady=5, sticky=EW)
            row += 1

            # Полка (выпадающий список)
            Label(add_window, text="Номер полки:").grid(row=row, column=0, padx=5, pady=5, sticky=W)
            shelf_var = StringVar()
            shelf_combobox = ttk.Combobox(add_window, textvariable=shelf_var, 
                                        values=[], state="readonly")
            shelf_combobox.grid(row=row, column=1, padx=5, pady=5, sticky=EW)
            row += 1

            # Тип детали (поле ввода)
            Label(add_window, text="Тип детали:").grid(row=row, column=0, padx=5, pady=5, sticky=W)
            type_entry = Entry(add_window)
            type_entry.grid(row=row, column=1, padx=5, pady=5, sticky=EW)
            row += 1

            # Вес (поле ввода)
            Label(add_window, text="Вес (кг):").grid(row=row, column=0, padx=5, pady=5, sticky=W)
            weight_entry = Entry(add_window)
            weight_entry.grid(row=row, column=1, padx=5, pady=5, sticky=EW)
            weight_entry.insert(0, "0.0")
            row += 1

            # Функция для обновления списка комнат при изменении склада
            def update_rooms(event=None):
                selected_warehouse = warehouse_var.get()
                if selected_warehouse in warehouse_ids:
                    warehouse_id = warehouse_ids[selected_warehouse]
                    try:
                        self.cursor.execute("""
                            SELECT room_id, room_number 
                            FROM room 
                            WHERE warehouseID = %s 
                            ORDER BY room_number
                        """, (warehouse_id,))
                        rooms = self.cursor.fetchall()
                        room_combobox['values'] = [str(number) for id, number in rooms]
                        
                        if rooms:
                            room_combobox.current(0)
                            room_var.set(str(rooms[0][1]))
                            update_racks()
                        else:
                            room_var.set('')
                            rack_var.set('')
                            shelf_var.set('')
                            rack_combobox['values'] = []
                            shelf_combobox['values'] = []
                    except Exception as e:
                        print(f"Error updating rooms: {e}")
                        room_combobox['values'] = []
                else:
                    room_combobox['values'] = []
                    rack_combobox['values'] = []
                    shelf_combobox['values'] = []

            # Функция для обновления списка стеллажей при изменении комнаты
            def update_racks(event=None):
                selected_warehouse = warehouse_var.get()
                selected_room = room_var.get()
                if selected_warehouse in warehouse_ids and selected_room:
                    warehouse_id = warehouse_ids[selected_warehouse]
                    try:
                        self.cursor.execute("""
                            SELECT rack_id, rack_number 
                            FROM rack 
                            WHERE roomID = (
                                SELECT room_id FROM room 
                                WHERE room_number = %s AND warehouseID = %s
                            )
                            ORDER BY rack_number
                        """, (int(selected_room), warehouse_id))
                        racks = self.cursor.fetchall()
                        rack_combobox['values'] = [str(number) for id, number in racks]
                        
                        if racks:
                            rack_combobox.current(0)
                            rack_var.set(str(racks[0][1]))
                            update_shelves()
                        else:
                            rack_var.set('')
                            shelf_var.set('')
                            shelf_combobox['values'] = []
                    except Exception as e:
                        print(f"Error updating racks: {e}")
                        rack_combobox['values'] = []
                else:
                    rack_combobox['values'] = []
                    shelf_combobox['values'] = []

            # Функция для обновления списка полок при изменении стеллажа
            def update_shelves(event=None):
                selected_warehouse = warehouse_var.get()
                selected_room = room_var.get()
                selected_rack = rack_var.get()
                if (selected_warehouse in warehouse_ids and selected_room and selected_rack):
                    warehouse_id = warehouse_ids[selected_warehouse]
                    try:
                        self.cursor.execute("""
                            SELECT shelf_id, shelf_number 
                            FROM shelf 
                            WHERE rackID = (
                                SELECT rack_id FROM rack 
                                WHERE rack_number = %s AND roomID = (
                                    SELECT room_id FROM room 
                                    WHERE room_number = %s AND warehouseID = %s
                                )
                            )
                            ORDER BY shelf_number
                        """, (int(selected_rack), int(selected_room), warehouse_id))
                        shelves = self.cursor.fetchall()
                        shelf_combobox['values'] = [str(number) for id, number in shelves]
                        
                        if shelves:
                            shelf_combobox.current(0)
                            shelf_var.set(str(shelves[0][1]))
                        else:
                            shelf_var.set('')
                    except Exception as e:
                        print(f"Error updating shelves: {e}")
                        shelf_combobox['values'] = []
                else:
                    shelf_combobox['values'] = []

            # Привязываем обработчики изменений
            warehouse_combobox.bind("<<ComboboxSelected>>", update_rooms)
            room_combobox.bind("<<ComboboxSelected>>", update_racks)
            rack_combobox.bind("<<ComboboxSelected>>", update_shelves)

            # Устанавливаем первый склад по умолчанию, если есть
            if warehouse_options:
                warehouse_combobox.current(0)
                warehouse_var.set(warehouse_options[0])
                update_rooms()

            def save_item():
                try:
                    # Проверяем, что все поля заполнены
                    if not all([warehouse_var.get(), room_var.get(), 
                            rack_var.get(), shelf_var.get(), 
                            type_entry.get(), weight_entry.get()]):
                        raise ValueError("Все поля должны быть заполнены")

                    # Получаем ID полки
                    self.cursor.execute("""
                        SELECT shelf_id FROM shelf 
                        WHERE shelf_number = %s AND rackID = (
                            SELECT rack_id FROM rack 
                            WHERE rack_number = %s AND roomID = (
                                SELECT room_id FROM room 
                                WHERE room_number = %s AND warehouseID = (
                                    SELECT warehouse_id FROM warehouse 
                                    WHERE warehouse_number = %s
                                )
                            )
                        )
                    """, (int(shelf_var.get()), int(rack_var.get()), int(room_var.get()), int(warehouse_var.get())))
                    
                    shelf_data = self.cursor.fetchone()
                    if not shelf_data:
                        raise ValueError("Полка не найдена в базе данных")
                    shelf_id = shelf_data[0]

                    # Проверяем вес
                    try:
                        weight = float(weight_entry.get())
                        if weight <= 0.0:
                            raise ValueError("Вес не может быть отрицательным")
                    except ValueError as e:
                        raise ValueError("Вес должен быть числом (например, 2.1)")
                    
                    # Проверка количества деталей на полке
                    self.cursor.execute("""
                        SELECT COUNT(*) FROM details WHERE shelfid = %s
                    """, (shelf_id,))
                    details_count = self.cursor.fetchone()[0]
                    
                    if details_count >= 5:
                        raise ValueError(f"На полке уже {details_count} деталей. Максимум - 5.")

                    # Вставляем деталь
                    self.cursor.execute("""
                        INSERT INTO details (shelfid, type_detail, weight)
                        VALUES (%s, %s, %s)
                    """, (shelf_id, type_entry.get(), weight))
                    
                    self.conn.commit()
                    self.load_warehouse()
                    add_window.destroy()
                    messagebox.showinfo("Успех", "Деталь успешно добавлена")
                except ValueError as ve:
                    messagebox.showerror("Ошибка", f"Неверные данные: {str(ve)}")
                except Exception as e:
                    self.conn.rollback()
                    messagebox.showerror("Ошибка", f"Не удалось добавить деталь: {str(e)}")
            
            # Кнопка сохранения
            Button(add_window, text="Сохранить", command=save_item).grid(
                row=row, column=0, columnspan=2, pady=10)
                
        except Exception as e:
            messagebox.showerror("Ошибка", f"Не удалось открыть форму: {str(e)}")

    def edit_warehouse_item(self):
        """Редактирование детали на складе с динамическими выпадающими списками"""
        if not self.can_edit_warehouse:
            messagebox.showerror("Ошибка", "У вас нет прав на редактирование деталей")
            return
            
        selected = self.warehouse_tree.selection()
        if not selected:
            messagebox.showwarning("Предупреждение", "Выберите деталь для редактирования")
            return
        
        item = self.warehouse_tree.item(selected[0])
        detail_id = item['values'][0]
        
        try:
            # Получаем текущие данные о детали
            self.cursor.execute("""
                SELECT 
                    d.detail_id, d.type_detail, d.weight,
                    s.shelf_id, s.shelf_number,
                    rk.rack_id, rk.rack_number,
                    r.room_id, r.room_number,
                    w.warehouse_id, w.warehouse_number
                FROM details d
                JOIN shelf s ON d.shelfid = s.shelf_id
                JOIN rack rk ON s.rackid = rk.rack_id
                JOIN room r ON rk.roomid = r.room_id
                JOIN warehouse w ON r.warehouseid = w.warehouse_id
                WHERE d.detail_id = %s
            """, (detail_id,))
            
            detail_data = self.cursor.fetchone()
            
            if not detail_data:
                messagebox.showerror("Ошибка", "Деталь не найдена")
                return
            
            edit_window = Toplevel(self.root)
            edit_window.title("Редактировать деталь")
            
            # Получаем списки для выпадающих списков
            self.cursor.execute("SELECT warehouse_id, warehouse_number FROM warehouse ORDER BY warehouse_number")
            warehouses = self.cursor.fetchall()
            warehouse_options = [str(number) for id, number in warehouses]
            warehouse_ids = {str(number): id for id, number in warehouses}

            # Создаем элементы формы с выпадающими списками
            row = 0
            
            # Склад
            Label(edit_window, text="Номер склада:").grid(row=row, column=0, padx=5, pady=5, sticky=W)
            warehouse_var = StringVar(value=str(detail_data[10]))  # warehouse_number
            warehouse_combobox = ttk.Combobox(edit_window, textvariable=warehouse_var, 
                                            values=warehouse_options, state="readonly")
            warehouse_combobox.grid(row=row, column=1, padx=5, pady=5, sticky=EW)
            row += 1
            
            # Комната
            Label(edit_window, text="Номер комнаты:").grid(row=row, column=0, padx=5, pady=5, sticky=W)
            room_var = StringVar(value=str(detail_data[8]))  # room_number
            room_combobox = ttk.Combobox(edit_window, textvariable=room_var, 
                                        values=[], state="readonly")
            room_combobox.grid(row=row, column=1, padx=5, pady=5, sticky=EW)
            row += 1
            
            # Стеллаж
            Label(edit_window, text="Номер стеллажа:").grid(row=row, column=0, padx=5, pady=5, sticky=W)
            rack_var = StringVar(value=str(detail_data[6]))  # rack_number
            rack_combobox = ttk.Combobox(edit_window, textvariable=rack_var, 
                                        values=[], state="readonly")
            rack_combobox.grid(row=row, column=1, padx=5, pady=5, sticky=EW)
            row += 1
            
            # Полка
            Label(edit_window, text="Номер полки:").grid(row=row, column=0, padx=5, pady=5, sticky=W)
            shelf_var = StringVar(value=str(detail_data[4]))  # shelf_number
            shelf_combobox = ttk.Combobox(edit_window, textvariable=shelf_var, 
                                        values=[], state="readonly")
            shelf_combobox.grid(row=row, column=1, padx=5, pady=5, sticky=EW)
            row += 1
            
            # Тип детали
            Label(edit_window, text="Тип детали:").grid(row=row, column=0, padx=5, pady=5, sticky=W)
            type_var = StringVar(value=detail_data[1])  # type_detail
            type_entry = Entry(edit_window, textvariable=type_var)
            type_entry.grid(row=row, column=1, padx=5, pady=5, sticky=EW)
            row += 1
            
            # Вес
            Label(edit_window, text="Вес (кг):").grid(row=row, column=0, padx=5, pady=5, sticky=W)
            weight_var = StringVar(value=str(detail_data[2]))  # weight
            weight_entry = Entry(edit_window, textvariable=weight_var)
            weight_entry.grid(row=row, column=1, padx=5, pady=5, sticky=EW)
            row += 1

            # Функции для обновления зависимых списков
            def update_rooms(event=None):
                selected_warehouse = warehouse_var.get()
                if selected_warehouse in warehouse_ids:
                    warehouse_id = warehouse_ids[selected_warehouse]
                    try:
                        self.cursor.execute("""
                            SELECT room_id, room_number 
                            FROM room 
                            WHERE warehouseID = %s 
                            ORDER BY room_number
                        """, (warehouse_id,))
                        rooms = self.cursor.fetchall()
                        room_combobox['values'] = [str(number) for id, number in rooms]
                        
                        # Устанавливаем текущее значение комнаты, если оно есть в списке
                        current_room = str(detail_data[8])
                        if current_room in [str(number) for id, number in rooms]:
                            room_var.set(current_room)
                        elif rooms:
                            room_combobox.current(0)
                            room_var.set(str(rooms[0][1]))
                        update_racks()
                    except Exception as e:
                        print(f"Error updating rooms: {e}")
                        room_combobox['values'] = []
                else:
                    room_combobox['values'] = []
            
            def update_racks(event=None):
                selected_warehouse = warehouse_var.get()
                selected_room = room_var.get()
                if selected_warehouse in warehouse_ids and selected_room:
                    warehouse_id = warehouse_ids[selected_warehouse]
                    try:
                        self.cursor.execute("""
                            SELECT rack_id, rack_number 
                            FROM rack 
                            WHERE roomID = (
                                SELECT room_id FROM room 
                                WHERE room_number = %s AND warehouseID = %s
                            )
                            ORDER BY rack_number
                        """, (int(selected_room), warehouse_id))
                        racks = self.cursor.fetchall()
                        rack_combobox['values'] = [str(number) for id, number in racks]
                        
                        # Устанавливаем текущее значение стеллажа, если оно есть в списке
                        current_rack = str(detail_data[6])
                        if current_rack in [str(number) for id, number in racks]:
                            rack_var.set(current_rack)
                        elif racks:
                            rack_combobox.current(0)
                            rack_var.set(str(racks[0][1]))
                        update_shelves()
                    except Exception as e:
                        print(f"Error updating racks: {e}")
                        rack_combobox['values'] = []
                else:
                    rack_combobox['values'] = []
            
            def update_shelves(event=None):
                selected_warehouse = warehouse_var.get()
                selected_room = room_var.get()
                selected_rack = rack_var.get()
                if (selected_warehouse in warehouse_ids and selected_room and selected_rack):
                    warehouse_id = warehouse_ids[selected_warehouse]
                    try:
                        self.cursor.execute("""
                            SELECT shelf_id, shelf_number 
                            FROM shelf 
                            WHERE rackID = (
                                SELECT rack_id FROM rack 
                                WHERE rack_number = %s AND roomID = (
                                    SELECT room_id FROM room 
                                    WHERE room_number = %s AND warehouseID = %s
                                )
                            )
                            ORDER BY shelf_number
                        """, (int(selected_rack), int(selected_room), warehouse_id))
                        shelves = self.cursor.fetchall()
                        shelf_combobox['values'] = [str(number) for id, number in shelves]
                        
                        # Устанавливаем текущее значение полки, если оно есть в списке
                        current_shelf = str(detail_data[4])
                        if current_shelf in [str(number) for id, number in shelves]:
                            shelf_var.set(current_shelf)
                        elif shelves:
                            shelf_combobox.current(0)
                            shelf_var.set(str(shelves[0][1]))
                    except Exception as e:
                        print(f"Error updating shelves: {e}")
                        shelf_combobox['values'] = []
                else:
                    shelf_combobox['values'] = []

            # Привязываем обработчики изменений
            warehouse_combobox.bind("<<ComboboxSelected>>", update_rooms)
            room_combobox.bind("<<ComboboxSelected>>", update_racks)
            rack_combobox.bind("<<ComboboxSelected>>", update_shelves)

            # Инициализируем данные сразу после создания формы
            update_rooms()
            
            def save_changes():
                try:
                    # Проверяем, что все поля заполнены
                    if not all([warehouse_var.get(), room_var.get(), 
                            rack_var.get(), shelf_var.get(), 
                            type_var.get(), weight_var.get()]):
                        raise ValueError("Все поля должны быть заполнены")
                    
                    # Получаем ID новой полки
                    self.cursor.execute("""
                        SELECT shelf_id FROM shelf 
                        WHERE shelf_number = %s AND rackID = (
                            SELECT rack_id FROM rack 
                            WHERE rack_number = %s AND roomID = (
                                SELECT room_id FROM room 
                                WHERE room_number = %s AND warehouseID = (
                                    SELECT warehouse_id FROM warehouse 
                                    WHERE warehouse_number = %s
                                )
                            )
                        )
                    """, (int(shelf_var.get()), int(rack_var.get()), int(room_var.get()), int(warehouse_var.get())))
                    
                    shelf_data = self.cursor.fetchone()
                    if not shelf_data:
                        raise ValueError("Полка не найдена в базе данных")
                    new_shelf_id = shelf_data[0]
                    
                    # Проверяем вес
                    try:
                        weight = float(weight_var.get())
                        if weight <= 0.0:
                            raise ValueError("Вес не может быть отрицательным")
                    except ValueError as e:
                        raise ValueError("Вес должен быть числом (например, 2.1)")
                    
                    # Проверка количества деталей на новой полке (если полка изменилась)
                    if new_shelf_id != detail_data[3]:  # Если полка изменилась
                        self.cursor.execute("""
                            SELECT COUNT(*) FROM details WHERE shelfid = %s
                        """, (new_shelf_id,))
                        details_count = self.cursor.fetchone()[0]
                        
                        if details_count >= 5:
                            raise ValueError(f"На новой полке уже {details_count} деталей. Максимум - 5.")

                    # Обновляем деталь
                    self.cursor.execute("""
                        UPDATE details 
                        SET shelfid = %s, type_detail = %s, weight = %s
                        WHERE detail_id = %s
                    """, (new_shelf_id, type_var.get(), weight, detail_id))
                    
                    self.conn.commit()
                    self.load_warehouse()
                    edit_window.destroy()
                    messagebox.showinfo("Успех", "Деталь успешно обновлена")
                except ValueError as ve:
                    messagebox.showerror("Ошибка", f"Неверные данные: {str(ve)}")
                except Exception as e:
                    self.conn.rollback()
                    messagebox.showerror("Ошибка", f"Не удалось обновить деталь: {str(e)}")
            
            # Кнопка сохранения
            Button(edit_window, text="Сохранить", command=save_changes).grid(
                row=row, column=0, columnspan=2, pady=10)
                
        except Exception as e:
            messagebox.showerror("Ошибка", f"Не удалось открыть форму редактирования: {str(e)}")
    
    def delete_warehouse_item(self):
        """Удаление детали со склада"""
        selected = self.warehouse_tree.selection()
        if not selected:
            messagebox.showwarning("Предупреждение", "Выберите деталь для удаления")
            return
        
        item = self.warehouse_tree.item(selected[0])
        detail_id = item['values'][0]
        
        # Check if detail is referenced in any invoices
        self.cursor.execute("SELECT COUNT(*) FROM invoice_detail WHERE detailid = %s", (detail_id,))
        reference_count = self.cursor.fetchone()[0]
        
        if reference_count > 0:
            messagebox.showerror("Ошибка", 
                            f"Невозможно удалить деталь: она используется в {reference_count} накладных")
            return
        
        if messagebox.askyesno("Подтверждение", f"Вы уверены, что хотите удалить деталь №{detail_id}?"):
            try:
                self.cursor.execute("DELETE FROM details WHERE detail_id = %s", (detail_id,))
                self.conn.commit()
                self.load_warehouse()
                
                # Проверяем, стала ли таблица пустой после удаления
                if len(self.warehouse_tree.get_children()) == 0 and self.current_search_conditions['warehouse']:
                    messagebox.showinfo("Информация", "Таблица пуста. Сброс условий поиска.")
                    self.current_search_conditions['warehouse'] = None
                    self.load_warehouse()
                    
                messagebox.showinfo("Успех", "Деталь успешно удалена")
            except Exception as e:
                self.conn.rollback()
                messagebox.showerror("Ошибка", f"Не удалось удалить деталь: {str(e)}")
    
    # Методы для работы с контрагентами
    def add_counteragent(self):
        """Добавление нового контрагента"""
        if not self.can_edit_counteragents:
            messagebox.showerror("Ошибка", "У вас нет прав на добавление накладных")
            return
        try:
            add_window = Toplevel(self.root)
            add_window.title("Добавить контрагента")
            
            # Создаем элементы формы
            Label(add_window, text="Название:").grid(row=0, column=0, padx=5, pady=5, sticky=W)
            name_entry = Entry(add_window)
            name_entry.grid(row=0, column=1, padx=5, pady=5, sticky=EW)
            
            Label(add_window, text="Контактное лицо:").grid(row=1, column=0, padx=5, pady=5, sticky=W)
            contact_entry = Entry(add_window)
            contact_entry.grid(row=1, column=1, padx=5, pady=5, sticky=EW)
            
            Label(add_window, text="Телефон:").grid(row=2, column=0, padx=5, pady=5, sticky=W)
            phone_entry = Entry(add_window)
            phone_entry.grid(row=2, column=1, padx=5, pady=5, sticky=EW)
            
            Label(add_window, text="Адрес:").grid(row=3, column=0, padx=5, pady=5, sticky=W)
            address_entry = Entry(add_window)
            address_entry.grid(row=3, column=1, padx=5, pady=5, sticky=EW)
            
            def save_counteragent():
                try:
                    self.cursor.execute("""
                        INSERT INTO counteragent (counteragent_name, contact_person, phone_number, address)
                        VALUES (%s, %s, %s, %s)
                    """, (
                        name_entry.get(),
                        contact_entry.get(),
                        int(phone_entry.get()),
                        address_entry.get()
                    ))
                    
                    self.conn.commit()
                    self.load_counteragents()
                    add_window.destroy()
                    messagebox.showinfo("Успех", "Контрагент успешно добавлен")
                except Exception as e:
                    self.conn.rollback()
                    messagebox.showerror("Ошибка", f"Не удалось добавить контрагента: {str(e)}")
            
            Button(add_window, text="Сохранить", command=save_counteragent).grid(row=4, column=0, columnspan=2, pady=10)
            
        except Exception as e:
            messagebox.showerror("Ошибка", f"Не удалось открыть форму: {str(e)}")
    
    def edit_counteragent(self):
        """Редактирование контрагента"""
        if not self.can_edit_counteragents:
            messagebox.showerror("Ошибка", "У вас нет прав на добавление накладных")
            return
        selected = self.counteragent_tree.selection()
        if not selected:
            messagebox.showwarning("Предупреждение", "Выберите контрагента для редактирования")
            return
        
        item = self.counteragent_tree.item(selected[0])
        counteragent_id = item['values'][0]
        
        try:
            # Получаем данные о контрагенте
            self.cursor.execute("SELECT * FROM counteragent WHERE counteragent_id = %s", (counteragent_id,))
            counteragent_data = self.cursor.fetchone()
            
            if not counteragent_data:
                messagebox.showerror("Ошибка", "Контрагент не найден")
                return
            
            edit_window = Toplevel(self.root)
            edit_window.title("Редактировать контрагента")
            
            # Создаем элементы формы с текущими значениями
            Label(edit_window, text="Название:").grid(row=0, column=0, padx=5, pady=5, sticky=W)
            name_entry = Entry(edit_window)
            name_entry.insert(0, counteragent_data[1])
            name_entry.grid(row=0, column=1, padx=5, pady=5, sticky=EW)
            
            Label(edit_window, text="Контактное лицо:").grid(row=1, column=0, padx=5, pady=5, sticky=W)
            contact_entry = Entry(edit_window)
            contact_entry.insert(0, counteragent_data[2])
            contact_entry.grid(row=1, column=1, padx=5, pady=5, sticky=EW)
            
            Label(edit_window, text="Телефон:").grid(row=2, column=0, padx=5, pady=5, sticky=W)
            phone_entry = Entry(edit_window)
            phone_entry.insert(0, str(counteragent_data[3]))
            phone_entry.grid(row=2, column=1, padx=5, pady=5, sticky=EW)
            
            Label(edit_window, text="Адрес:").grid(row=3, column=0, padx=5, pady=5, sticky=W)
            address_entry = Entry(edit_window)
            address_entry.insert(0, counteragent_data[4])
            address_entry.grid(row=3, column=1, padx=5, pady=5, sticky=EW)
            
            def save_changes():
                try:
                    self.cursor.execute("""
                        UPDATE counteragent 
                        SET 
                            counteragent_name = %s,
                            contact_person = %s,
                            phone_number = %s,
                            address = %s
                        WHERE counteragent_id = %s
                    """, (
                        name_entry.get(),
                        contact_entry.get(),
                        int(phone_entry.get()),
                        address_entry.get(),
                        counteragent_id
                    ))
                    
                    self.conn.commit()
                    self.load_counteragents()
                    edit_window.destroy()
                    messagebox.showinfo("Успех", "Контрагент успешно обновлен")
                except Exception as e:
                    self.conn.rollback()
                    messagebox.showerror("Ошибка", f"Не удалось обновить контрагента: {str(e)}")
            
            Button(edit_window, text="Сохранить", command=save_changes).grid(row=4, column=0, columnspan=2, pady=10)
            
        except Exception as e:
            messagebox.showerror("Ошибка", f"Не удалось открыть форму: {str(e)}")
    
    def delete_counteragent(self):
        """Удаление контрагента"""
        selected = self.counteragent_tree.selection()
        if not selected:
            messagebox.showwarning("Предупреждение", "Выберите контрагента для удаления")
            return
        
        item = self.counteragent_tree.item(selected[0])
        counteragent_id = item['values'][0]
        counteragent_name = item['values'][1]
        
        if messagebox.askyesno("Подтверждение", f"Вы уверены, что хотите удалить контрагента '{counteragent_name}'?"):
            try:
                self.cursor.execute("DELETE FROM counteragent WHERE counteragent_id = %s", (counteragent_id,))
                self.conn.commit()
                self.load_counteragents()
                
                # Проверяем, стала ли таблица пустой после удаления
                if len(self.counteragent_tree.get_children()) == 0 and self.current_search_conditions['counteragent']:
                    messagebox.showinfo("Информация", "Таблица пуста. Сброс условий поиска.")
                    self.current_search_conditions['counteragent'] = None
                    self.load_counteragents()
                    
                messagebox.showinfo("Успех", "Контрагент успешно удален")
            except Exception as e:
                self.conn.rollback()
                messagebox.showerror("Ошибка", f"Не удалось удалить контрагента: {str(e)}")
    
    # Методы для работы с сотрудниками
    def add_employee(self):
        """Добавление нового сотрудника"""
        if not self.can_edit_employees:
            messagebox.showerror("Ошибка", "У вас нет прав на добавление накладных")
            return
        try:
            add_window = Toplevel(self.root)
            add_window.title("Добавить сотрудника")
            
            # Создаем элементы формы
            Label(add_window, text="Роль:").grid(row=0, column=0, padx=5, pady=5, sticky=W)
            role_var = StringVar()
            role_combobox = ttk.Combobox(add_window, textvariable=role_var, 
                                         values=["Кладовщик", "Менеджер склада", "Владелец"])
            role_combobox.grid(row=0, column=1, padx=5, pady=5, sticky=EW)
            
            Label(add_window, text="Фамилия:").grid(row=1, column=0, padx=5, pady=5, sticky=W)
            last_name_entry = Entry(add_window)
            last_name_entry.grid(row=1, column=1, padx=5, pady=5, sticky=EW)
            
            Label(add_window, text="Имя:").grid(row=2, column=0, padx=5, pady=5, sticky=W)
            first_name_entry = Entry(add_window)
            first_name_entry.grid(row=2, column=1, padx=5, pady=5, sticky=EW)
            
            Label(add_window, text="Отчество:").grid(row=3, column=0, padx=5, pady=5, sticky=W)
            patronymic_entry = Entry(add_window)
            patronymic_entry.grid(row=3, column=1, padx=5, pady=5, sticky=EW)
            
            def save_employee():
                try:
                    self.cursor.execute("""
                        INSERT INTO employee (employee_role, last_name, first_name, patronymic)
                        VALUES (%s, %s, %s, %s)
                    """, (
                        role_var.get(),
                        last_name_entry.get(),
                        first_name_entry.get(),
                        patronymic_entry.get()
                    ))
                    
                    self.conn.commit()
                    self.load_employees()
                    add_window.destroy()
                    messagebox.showinfo("Успех", "Сотрудник успешно добавлен")
                except Exception as e:
                    self.conn.rollback()
                    messagebox.showerror("Ошибка", f"Не удалось добавить сотрудника: {str(e)}")
            
            Button(add_window, text="Сохранить", command=save_employee).grid(row=4, column=0, columnspan=2, pady=10)
            
        except Exception as e:
            messagebox.showerror("Ошибка", f"Не удалось открыть форму: {str(e)}")
    
    def edit_employee(self):
        """Редактирование сотрудника"""
        if not self.can_edit_employees:
            messagebox.showerror("Ошибка", "У вас нет прав на добавление накладных")
            return
        selected = self.employee_tree.selection()
        if not selected:
            messagebox.showwarning("Предупреждение", "Выберите сотрудника для редактирования")
            return
        
        item = self.employee_tree.item(selected[0])
        employee_id = item['values'][0]
        
        try:
            # Получаем данные о сотруднике
            self.cursor.execute("SELECT * FROM employee WHERE employee_id = %s", (employee_id,))
            employee_data = self.cursor.fetchone()
            
            if not employee_data:
                messagebox.showerror("Ошибка", "Сотрудник не найден")
                return
            
            edit_window = Toplevel(self.root)
            edit_window.title("Редактировать сотрудника")
            
            # Создаем элементы формы с текущими значениями
            Label(edit_window, text="Роль:").grid(row=0, column=0, padx=5, pady=5, sticky=W)
            role_var = StringVar()
            role_combobox = ttk.Combobox(edit_window, textvariable=role_var, 
                                        values=["Кладовщик", "Менеджер склада", "Владелец"])
            role_combobox.set(employee_data[1])
            role_combobox.grid(row=0, column=1, padx=5, pady=5, sticky=EW)
            
            Label(edit_window, text="Фамилия:").grid(row=1, column=0, padx=5, pady=5, sticky=W)
            last_name_entry = Entry(edit_window)
            last_name_entry.insert(0, employee_data[2])
            last_name_entry.grid(row=1, column=1, padx=5, pady=5, sticky=EW)
            
            Label(edit_window, text="Имя:").grid(row=2, column=0, padx=5, pady=5, sticky=W)
            first_name_entry = Entry(edit_window)
            first_name_entry.insert(0, employee_data[3])
            first_name_entry.grid(row=2, column=1, padx=5, pady=5, sticky=EW)
            
            Label(edit_window, text="Отчество:").grid(row=3, column=0, padx=5, pady=5, sticky=W)
            patronymic_entry = Entry(edit_window)
            patronymic_entry.insert(0, employee_data[4])
            patronymic_entry.grid(row=3, column=1, padx=5, pady=5, sticky=EW)
            
            def save_changes():
                try:
                    self.cursor.execute("""
                        UPDATE employee 
                        SET 
                            employee_role = %s,
                            last_name = %s,
                            first_name = %s,
                            patronymic = %s
                        WHERE employee_id = %s
                    """, (
                        role_var.get(),
                        last_name_entry.get(),
                        first_name_entry.get(),
                        patronymic_entry.get(),
                        employee_id
                    ))
                    
                    self.conn.commit()
                    self.load_employees()
                    edit_window.destroy()
                    messagebox.showinfo("Успех", "Сотрудник успешно обновлен")
                except Exception as e:
                    self.conn.rollback()
                    messagebox.showerror("Ошибка", f"Не удалось обновить сотрудника: {str(e)}")
            
            Button(edit_window, text="Сохранить", command=save_changes).grid(row=4, column=0, columnspan=2, pady=10)
            
        except Exception as e:
            messagebox.showerror("Ошибка", f"Не удалось открыть форму: {str(e)}")
    
    def delete_employee(self):
        """Удаление сотрудника"""
        selected = self.employee_tree.selection()
        if not selected:
            messagebox.showwarning("Предупреждение", "Выберите сотрудника для удаления")
            return
        
        item = self.employee_tree.item(selected[0])
        employee_id = item['values'][0]
        employee_name = f"{item['values'][2]} {item['values'][3]} {item['values'][4]}"
        
        if messagebox.askyesno("Подтверждение", f"Вы уверены, что хотите удалить сотрудника '{employee_name}'?"):
            try:
                self.cursor.execute("DELETE FROM employee WHERE employee_id = %s", (employee_id,))
                self.conn.commit()
                self.load_employees()
                
                # Проверяем, стала ли таблица пустой после удаления
                if len(self.employee_tree.get_children()) == 0 and self.current_search_conditions['employee']:
                    messagebox.showinfo("Информация", "Таблица пуста. Сброс условий поиска.")
                    self.current_search_conditions['employee'] = None
                    self.load_employees()
                    
                messagebox.showinfo("Успех", "Сотрудник успешно удален")
            except Exception as e:
                self.conn.rollback()
                messagebox.showerror("Ошибка", f"Не удалось удалить сотрудника: {str(e)}")

def create_connection(login, password):
    try:
        connection = psycopg2.connect(
            host="127.0.0.1",
            user=login,
            password=password,
            database="Warehouse_DB"
        )
        print("[INFO] PostgreSQL connection open.")
        return connection
    except Exception as ex:
        print(f"[CONNECTION ERROR] Failed to connect: {ex}")
        return None

def start_work():
    login, password = entry_name.get(), entry_password.get()
    print(f"[AUTH] Attempting login for user: {login}")
    active_user = create_connection(login, password)
    if active_user is not None:
        print("[AUTH] Login successful")
        window.destroy()
        main_win = Tk()
        app = WarehouseApp(main_win, login, password, active_user)  
        main_win.mainloop()
    else:
        print("[AUTH] Login failed")
        messagebox.showerror('Ошибка авторизации', 
                           'Произошла ошибка авторизации пользователя! Проверьте логин и пароль.')
        
window = Tk()
window.geometry('%dx%d+%d+%d' % (500, 400, 
                                (window.winfo_screenwidth()/2) - (500/2), 
                                (window.winfo_screenheight()/2) - (400/2)))
window.title("Склад запчастей")
window.configure(background="#FFFAFA")
middle_window_x = 500 / 2
middle_window_y = 400 / 3
title_start = ttk.Label(master=window, text="Войдите в систему", 
                       font=("algerian", 20), background="#FFFAFA")
title_start.place(x=middle_window_x, y=100, anchor="center")
title_login = ttk.Label(text="Логин:", font=("algerian", 10), background="#FFFAFA")
title_login.place(x=middle_window_x, y=140, anchor="center")
title_password = ttk.Label(text="Пароль:", font=("algerian", 10), background="#FFFAFA")
title_password.place(x=middle_window_x, y=200, anchor="center")
entry_name = ttk.Entry(width=50)
entry_name.place(x=middle_window_x, y=middle_window_y+30, anchor="center")
entry_password = ttk.Entry(width=50, show="*")
entry_password.place(x=middle_window_x, y=middle_window_y+90, anchor="center")
btn_in = ttk.Button(text="Войти", command=start_work)
btn_in.place(x=middle_window_x, y=middle_window_y+160, anchor="center")
window.mainloop()