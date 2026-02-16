from django.shortcuts import render, get_object_or_404, redirect
from django.contrib.auth.decorators import login_required
from django.db.models import Q, Sum, Count
from django.utils import timezone
from datetime import timedelta
from django.contrib import messages
from django.http import HttpResponse
from io import BytesIO
from .models import *
from .forms import *


# ==================== ОСНОВНЫЕ СТРАНИЦЫ ====================

@login_required
def dashboard(request):
    """Главная страница панели управления"""
    total_orders = Order.objects.count()
    pending_orders = Order.objects.filter(status__code='created').count()
    active_couriers = User.objects.filter(role__name='courier', status='works').count()
    today_orders = Order.objects.filter(created_at__date=timezone.now().date()).count()

    recent_orders = Order.objects.select_related('client', 'status', 'courier').order_by('-created_at')[:10]

    context = {
        'total_orders': total_orders,
        'pending_orders': pending_orders,
        'active_couriers': active_couriers,
        'today_orders': today_orders,
        'recent_orders': recent_orders,
    }
    return render(request, 'delservice_app/dashboard.html', context)


@login_required
def reports(request):
    """Формирование отчётов"""
    thirty_days_ago = timezone.now() - timedelta(days=30)
    courier_stats = User.objects.filter(
        role__name='courier',
        delivered_orders__created_at__gte=thirty_days_ago
    ).annotate(
        total_deliveries=Count('delivered_orders'),
        total_earnings=Sum('delivered_orders__delivery_cost')
    ).order_by('-total_deliveries')

    status_stats = OrderStatus.objects.annotate(
        order_count=Count('order')
    ).order_by('sort_order')

    payment_stats = PaymentMethod.objects.annotate(
        total_amount=Sum('payment__amount'),
        payment_count=Count('payment')
    )

    context = {
        'courier_stats': courier_stats,
        'status_stats': status_stats,
        'payment_stats': payment_stats,
    }
    return render(request, 'delservice_app/reports.html', context)


@login_required
def generate_pdf_report(request):
    """Генерация отчёта в формате PDF"""
    try:
        from reportlab.lib.pagesizes import A4
        from reportlab.lib import colors
        from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
        from reportlab.platypus import SimpleDocTemplate, Table, TableStyle, Paragraph, Spacer
        from reportlab.pdfbase import pdfmetrics
        from reportlab.pdfbase.ttfonts import TTFont
        from reportlab.lib.units import inch
    except ImportError:
        messages.error(request, 'Библиотека reportlab не установлена. Установите: pip install reportlab')
        return redirect('delservice_app:reports')

    # Регистрация шрифта с поддержкой кириллицы
    pdfmetrics.registerFont(TTFont('DejaVuSans', 'DejaVuSans.ttf'))
    pdfmetrics.registerFont(TTFont('DejaVuSans-Bold', 'DejaVuSans-Bold.ttf'))

    buffer = BytesIO()
    doc = SimpleDocTemplate(buffer, pagesize=A4)
    elements = []

    styles = getSampleStyleSheet()

    # Создание стилей с кириллическим шрифтом
    title_style = ParagraphStyle(
        'CustomTitle',
        parent=styles['Heading1'],
        fontName='DejaVuSans-Bold',
        fontSize=16,
        spaceAfter=30,
        alignment=1,
        textColor=colors.black
    )

    heading_style = ParagraphStyle(
        'CustomHeading',
        parent=styles['Heading2'],
        fontName='DejaVuSans-Bold',
        fontSize=14,
        spaceAfter=12,
        spaceBefore=20,
        textColor=colors.black
    )

    normal_style = ParagraphStyle(
        'CustomNormal',
        parent=styles['Normal'],
        fontName='DejaVuSans',
        fontSize=10,
        textColor=colors.black
    )

    # Заголовок отчёта
    elements.append(Paragraph('Отчёт о деятельности службы доставки', title_style))
    elements.append(Paragraph(f'Дата формирования: {timezone.now().strftime("%d.%m.%Y %H:%M")}', normal_style))
    elements.append(Spacer(1, 20))

    # Статистика по курьерам
    elements.append(Paragraph('Эффективность курьеров (за последние 30 дней)', heading_style))

    thirty_days_ago = timezone.now() - timedelta(days=30)
    courier_stats = User.objects.filter(
        role__name='courier',
        delivered_orders__created_at__gte=thirty_days_ago
    ).annotate(
        total_deliveries=Count('delivered_orders'),
        total_earnings=Sum('delivered_orders__delivery_cost')
    ).order_by('-total_deliveries')

    if courier_stats.exists():
        courier_data = [['Курьер', 'Количество доставок', 'Общий доход (₽)']]
        for courier in courier_stats:
            courier_data.append([
                courier.full_name,
                str(courier.total_deliveries),
                f"{courier.total_earnings or 0} ₽"
            ])

        courier_table = Table(courier_data, colWidths=[2.5 * inch, 1.7 * inch, 1.3 * inch])
        courier_table.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (-1, 0), colors.grey),
            ('TEXTCOLOR', (0, 0), (-1, 0), colors.whitesmoke),
            ('ALIGN', (0, 0), (-1, -1), 'CENTER'),
            ('FONTNAME', (0, 0), (-1, 0), 'DejaVuSans-Bold'),
            ('FONTNAME', (0, 1), (-1, -1), 'DejaVuSans'),
            ('FONTSIZE', (0, 0), (-1, -1), 10),
            ('BOTTOMPADDING', (0, 0), (-1, 0), 12),
            ('GRID', (0, 0), (-1, -1), 1, colors.black),
            ('ROWBACKGROUNDS', (0, 1), (-1, -1), [colors.lightgrey, colors.white]),
            ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
        ]))
        elements.append(courier_table)
    else:
        elements.append(Paragraph('Нет данных за указанный период', normal_style))

    elements.append(Spacer(1, 30))

    # Статистика по статусам заказов
    elements.append(Paragraph('Статистика заказов по статусам', heading_style))

    status_stats = OrderStatus.objects.annotate(
        order_count=Count('order')
    ).order_by('sort_order')

    if status_stats.exists():
        status_data = [['Статус', 'Количество заказов']]
        for status in status_stats:
            status_data.append([status.name, str(status.order_count)])

        status_table = Table(status_data, colWidths=[3 * inch, 2.5 * inch])
        status_table.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (-1, 0), colors.grey),
            ('TEXTCOLOR', (0, 0), (-1, 0), colors.whitesmoke),
            ('ALIGN', (0, 0), (-1, -1), 'CENTER'),
            ('FONTNAME', (0, 0), (-1, 0), 'DejaVuSans-Bold'),
            ('FONTNAME', (0, 1), (-1, -1), 'DejaVuSans'),
            ('FONTSIZE', (0, 0), (-1, -1), 10),
            ('BOTTOMPADDING', (0, 0), (-1, 0), 12),
            ('GRID', (0, 0), (-1, -1), 1, colors.black),
            ('ROWBACKGROUNDS', (0, 1), (-1, -1), [colors.lightgrey, colors.white]),
            ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
        ]))
        elements.append(status_table)
    else:
        elements.append(Paragraph('Нет данных', normal_style))

    elements.append(Spacer(1, 30))

    # Статистика по способам оплаты
    elements.append(Paragraph('Доходы по способам оплаты', heading_style))

    payment_stats = PaymentMethod.objects.annotate(
        total_amount=Sum('payment__amount'),
        payment_count=Count('payment')
    )

    if payment_stats.exists():
        # Используем более короткий заголовок для третьей колонки
        payment_data = [['Способ оплаты', 'Общая сумма (₽)', 'Кол-во платежей']]
        for payment in payment_stats:
            payment_data.append([
                payment.name,
                f"{payment.total_amount or 0} ₽",
                str(payment.payment_count)
            ])

        # Увеличиваем ширину третьей колонки
        payment_table = Table(payment_data, colWidths=[2.5 * inch, 2 * inch, 1.7 * inch])
        payment_table.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (-1, 0), colors.grey),
            ('TEXTCOLOR', (0, 0), (-1, 0), colors.whitesmoke),
            ('ALIGN', (0, 0), (-1, -1), 'CENTER'),
            ('FONTNAME', (0, 0), (-1, 0), 'DejaVuSans-Bold'),
            ('FONTNAME', (0, 1), (-1, -1), 'DejaVuSans'),
            ('FONTSIZE', (0, 0), (-1, -1), 10),
            ('BOTTOMPADDING', (0, 0), (-1, 0), 12),
            ('GRID', (0, 0), (-1, -1), 1, colors.black),
            ('ROWBACKGROUNDS', (0, 1), (-1, -1), [colors.lightgrey, colors.white]),
            ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ('WORDWRAP', (0, 0), (-1, -1), True),  # Включаем перенос слов
        ]))
        elements.append(payment_table)
    else:
        elements.append(Paragraph('Нет данных', normal_style))

    # Формирование документа
    doc.build(elements)

    # Подготовка ответа
    buffer.seek(0)
    response = HttpResponse(buffer, content_type='application/pdf')
    response['Content-Disposition'] = f'attachment; filename="report_{timezone.now().strftime("%Y%m%d_%H%M")}.pdf"'

    return response


# ==================== УПРАВЛЕНИЕ ЗАКАЗАМИ ====================

@login_required
def order_list(request):
    """Список заказов с поиском и фильтрацией"""
    form = OrderSearchForm(request.GET or None)
    orders = Order.objects.select_related(
        'client', 'status', 'courier', 'payment_method', 'delivery_address'
    ).prefetch_related('items__product').order_by('-created_at')

    if form.is_valid():
        if form.cleaned_data.get('client_name'):
            orders = orders.filter(
                Q(client__full_name__icontains=form.cleaned_data['client_name']) |
                Q(client__phone__icontains=form.cleaned_data['client_name'])
            )

        if form.cleaned_data.get('status'):
            orders = orders.filter(status__code=form.cleaned_data['status'])

        if form.cleaned_data.get('date_from'):
            orders = orders.filter(created_at__date__gte=form.cleaned_data['date_from'])

        if form.cleaned_data.get('date_to'):
            orders = orders.filter(created_at__date__lte=form.cleaned_data['date_to'])

        if form.cleaned_data.get('courier'):
            orders = orders.filter(courier_id=form.cleaned_data['courier'])

    from django.core.paginator import Paginator
    paginator = Paginator(orders, 20)
    page_number = request.GET.get('page', 1)
    page_obj = paginator.get_page(page_number)

    context = {
        'orders': page_obj,
        'form': form,
        'page_obj': page_obj,
    }
    return render(request, 'delservice_app/order_list.html', context)


@login_required
def order_detail(request, order_id):
    """Детальная информация о заказе"""
    order = get_object_or_404(Order, id=order_id)
    items = order.items.select_related('product')

    payment = getattr(order, 'payment', None)
    review = getattr(order, 'review', None)

    context = {
        'order': order,
        'items': items,
        'payment': payment,
        'review': review,
    }
    return render(request, 'delservice_app/order_detail.html', context)


@login_required
def order_create(request):
    """Создание нового заказа"""
    if request.method == 'POST':
        form = OrderForm(request.POST)
        if form.is_valid():
            order = form.save(commit=False)
            order.order_total = 0
            order.save()
            messages.success(request, 'Заказ успешно создан')
            return redirect('delservice_app:order_detail', order_id=order.id)
    else:
        form = OrderForm()

    context = {'form': form, 'title': 'Создание заказа'}
    return render(request, 'delservice_app/order_form.html', context)


@login_required
def order_update(request, order_id):
    """Редактирование заказа"""
    order = get_object_or_404(Order, id=order_id)

    if request.method == 'POST':
        form = OrderForm(request.POST, instance=order)
        if form.is_valid():
            form.save()
            messages.success(request, 'Заказ успешно обновлён')
            return redirect('delservice_app:order_detail', order_id=order.id)
    else:
        form = OrderForm(instance=order)

    context = {'form': form, 'title': 'Редактирование заказа', 'order': order}
    return render(request, 'delservice_app/order_form.html', context)


@login_required
def order_delete(request, order_id):
    """Удаление заказа"""
    order = get_object_or_404(Order, id=order_id)

    if request.method == 'POST':
        order.delete()
        messages.success(request, 'Заказ успешно удалён')
        return redirect('delservice_app:order_list')

    context = {'order': order}
    return render(request, 'delservice_app/order_confirm_delete.html', context)


# ==================== УПРАВЛЕНИЕ КЛИЕНТАМИ ====================

@login_required
def client_list(request):
    """Список клиентов"""
    search = request.GET.get('search', '')
    clients = Client.objects.all()

    if search:
        clients = clients.filter(
            Q(full_name__icontains=search) |
            Q(email__icontains=search) |
            Q(phone__icontains=search)
        )

    clients = clients.order_by('-registration_date')

    context = {'clients': clients, 'search': search}
    return render(request, 'delservice_app/client_list.html', context)


@login_required
def client_create(request):
    """Создание клиента"""
    if request.method == 'POST':
        form = ClientForm(request.POST)
        if form.is_valid():
            form.save()
            messages.success(request, 'Клиент успешно создан')
            return redirect('delservice_app:client_list')
    else:
        form = ClientForm()

    context = {'form': form, 'title': 'Создание клиента'}
    return render(request, 'delservice_app/client_form.html', context)


@login_required
def client_update(request, client_id):
    """Редактирование клиента"""
    client = get_object_or_404(Client, id=client_id)

    if request.method == 'POST':
        form = ClientForm(request.POST, instance=client)
        if form.is_valid():
            form.save()
            messages.success(request, 'Клиент успешно обновлён')
            return redirect('delservice_app:client_list')
    else:
        form = ClientForm(instance=client)

    context = {'form': form, 'title': 'Редактирование клиента', 'client': client}
    return render(request, 'delservice_app/client_form.html', context)


@login_required
def client_delete(request, client_id):
    """Удаление клиента"""
    client = get_object_or_404(Client, id=client_id)

    if request.method == 'POST':
        client.delete()
        messages.success(request, 'Клиент успешно удалён')
        return redirect('delservice_app:client_list')

    context = {'client': client}
    return render(request, 'delservice_app/client_confirm_delete.html', context)


# ==================== УПРАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯМИ (СОТРУДНИКАМИ) ====================

@login_required
def user_list(request):
    """Список пользователей (сотрудников)"""
    search = request.GET.get('search', '')
    users = User.objects.select_related('role').all()

    if search:
        users = users.filter(
            Q(full_name__icontains=search) |
            Q(login__icontains=search) |
            Q(phone__icontains=search)
        )

    users = users.order_by('hire_date')

    context = {'users': users, 'search': search}
    return render(request, 'delservice_app/user_list.html', context)


@login_required
def user_create(request):
    """Создание пользователя"""
    if request.method == 'POST':
        form = UserForm(request.POST)
        if form.is_valid():
            form.save()
            messages.success(request, 'Пользователь успешно создан')
            return redirect('delservice_app:user_list')
    else:
        form = UserForm()

    context = {'form': form, 'title': 'Создание пользователя'}
    return render(request, 'delservice_app/user_form.html', context)


@login_required
def user_update(request, user_id):
    """Редактирование пользователя"""
    user = get_object_or_404(User, id=user_id)

    if request.method == 'POST':
        form = UserForm(request.POST, instance=user)
        if form.is_valid():
            form.save()
            messages.success(request, 'Пользователь успешно обновлён')
            return redirect('delservice_app:user_list')
    else:
        form = UserForm(instance=user)

    context = {'form': form, 'title': 'Редактирование пользователя', 'user': user}
    return render(request, 'delservice_app/user_form.html', context)


@login_required
def user_delete(request, user_id):
    """Удаление пользователя"""
    user = get_object_or_404(User, id=user_id)

    if request.method == 'POST':
        user.delete()
        messages.success(request, 'Пользователь успешно удалён')
        return redirect('delservice_app:user_list')

    context = {'user': user}
    return render(request, 'delservice_app/user_confirm_delete.html', context)


# ==================== УПРАВЛЕНИЕ РОЛЯМИ ====================

@login_required
def role_list(request):
    """Список ролей"""
    roles = Role.objects.all().order_by('id')
    context = {'roles': roles}
    return render(request, 'delservice_app/role_list.html', context)


@login_required
def role_create(request):
    """Создание роли"""
    if request.method == 'POST':
        form = RoleForm(request.POST)
        if form.is_valid():
            form.save()
            messages.success(request, 'Роль успешно создана')
            return redirect('delservice_app:role_list')
    else:
        form = RoleForm()

    context = {'form': form, 'title': 'Создание роли'}
    return render(request, 'delservice_app/role_form.html', context)


@login_required
def role_update(request, role_id):
    """Редактирование роли"""
    role = get_object_or_404(Role, id=role_id)

    if request.method == 'POST':
        form = RoleForm(request.POST, instance=role)
        if form.is_valid():
            form.save()
            messages.success(request, 'Роль успешно обновлена')
            return redirect('delservice_app:role_list')
    else:
        form = RoleForm(instance=role)

    context = {'form': form, 'title': 'Редактирование роли', 'role': role}
    return render(request, 'delservice_app/role_form.html', context)


@login_required
def role_delete(request, role_id):
    """Удаление роли"""
    role = get_object_or_404(Role, id=role_id)

    if request.method == 'POST':
        role.delete()
        messages.success(request, 'Роль успешно удалена')
        return redirect('delservice_app:role_list')

    context = {'role': role}
    return render(request, 'delservice_app/role_confirm_delete.html', context)


# ==================== УПРАВЛЕНИЕ ТОВАРАМИ ====================

@login_required
def product_list(request):
    """Список товаров"""
    search = request.GET.get('search', '')
    products = Product.objects.all()

    if search:
        products = products.filter(
            Q(name__icontains=search) |
            Q(description__icontains=search)
        )

    products = products.order_by('name')

    context = {'products': products, 'search': search}
    return render(request, 'delservice_app/product_list.html', context)


@login_required
def product_create(request):
    """Создание товара"""
    if request.method == 'POST':
        form = ProductForm(request.POST)
        if form.is_valid():
            form.save()
            messages.success(request, 'Товар успешно создан')
            return redirect('delservice_app:product_list')
    else:
        form = ProductForm()

    context = {'form': form, 'title': 'Создание товара'}
    return render(request, 'delservice_app/product_form.html', context)


@login_required
def product_update(request, product_id):
    """Редактирование товара"""
    product = get_object_or_404(Product, id=product_id)

    if request.method == 'POST':
        form = ProductForm(request.POST, instance=product)
        if form.is_valid():
            form.save()
            messages.success(request, 'Товар успешно обновлён')
            return redirect('delservice_app:product_list')
    else:
        form = ProductForm(instance=product)

    context = {'form': form, 'title': 'Редактирование товара', 'product': product}
    return render(request, 'delservice_app/product_form.html', context)


@login_required
def product_delete(request, product_id):
    """Удаление товара"""
    product = get_object_or_404(Product, id=product_id)

    if request.method == 'POST':
        product.delete()
        messages.success(request, 'Товар успешно удалён')
        return redirect('delservice_app:product_list')

    context = {'product': product}
    return render(request, 'delservice_app/product_confirm_delete.html', context)


# ==================== УПРАВЛЕНИЕ АДРЕСАМИ ====================

@login_required
def address_list(request):
    """Список адресов"""
    search = request.GET.get('search', '')
    addresses = Address.objects.all()

    if search:
        addresses = addresses.filter(
            Q(street__icontains=search) |
            Q(house_number__icontains=search)
        )

    addresses = addresses.order_by('street', 'house_number')

    context = {'addresses': addresses, 'search': search}
    return render(request, 'delservice_app/address_list.html', context)


@login_required
def address_create(request):
    """Создание адреса"""
    if request.method == 'POST':
        form = AddressForm(request.POST)
        if form.is_valid():
            form.save()
            messages.success(request, 'Адрес успешно создан')
            return redirect('delservice_app:address_list')
    else:
        form = AddressForm()

    context = {'form': form, 'title': 'Создание адреса'}
    return render(request, 'delservice_app/address_form.html', context)


@login_required
def address_update(request, address_id):
    """Редактирование адреса"""
    address = get_object_or_404(Address, id=address_id)

    if request.method == 'POST':
        form = AddressForm(request.POST, instance=address)
        if form.is_valid():
            form.save()
            messages.success(request, 'Адрес успешно обновлён')
            return redirect('delservice_app:address_list')
    else:
        form = AddressForm(instance=address)

    context = {'form': form, 'title': 'Редактирование адреса', 'address': address}
    return render(request, 'delservice_app/address_form.html', context)


@login_required
def address_delete(request, address_id):
    """Удаление адреса"""
    address = get_object_or_404(Address, id=address_id)

    if request.method == 'POST':
        address.delete()
        messages.success(request, 'Адрес успешно удалён')
        return redirect('delservice_app:address_list')

    context = {'address': address}
    return render(request, 'delservice_app/address_confirm_delete.html', context)


# ==================== УПРАВЛЕНИЕ СТАТУСАМИ ЗАКАЗОВ ====================

@login_required
def order_status_list(request):
    """Список статусов заказов"""
    statuses = OrderStatus.objects.all().order_by('sort_order')
    context = {'statuses': statuses}
    return render(request, 'delservice_app/order_status_list.html', context)


@login_required
def order_status_create(request):
    """Создание статуса заказа"""
    if request.method == 'POST':
        form = OrderStatusForm(request.POST)
        if form.is_valid():
            form.save()
            messages.success(request, 'Статус успешно создан')
            return redirect('delservice_app:order_status_list')
    else:
        form = OrderStatusForm()

    context = {'form': form, 'title': 'Создание статуса'}
    return render(request, 'delservice_app/order_status_form.html', context)


@login_required
def order_status_update(request, status_id):
    """Редактирование статуса заказа"""
    status = get_object_or_404(OrderStatus, id=status_id)

    if request.method == 'POST':
        form = OrderStatusForm(request.POST, instance=status)
        if form.is_valid():
            form.save()
            messages.success(request, 'Статус успешно обновлён')
            return redirect('delservice_app:order_status_list')
    else:
        form = OrderStatusForm(instance=status)

    context = {'form': form, 'title': 'Редактирование статуса', 'status': status}
    return render(request, 'delservice_app/order_status_form.html', context)


@login_required
def order_status_delete(request, status_id):
    """Удаление статуса заказа"""
    status = get_object_or_404(OrderStatus, id=status_id)

    if request.method == 'POST':
        status.delete()
        messages.success(request, 'Статус успешно удалён')
        return redirect('delservice_app:order_status_list')

    context = {'status': status}
    return render(request, 'delservice_app/order_status_confirm_delete.html', context)


# ==================== УПРАВЛЕНИЕ СПОСОБАМИ ОПЛАТЫ ====================

@login_required
def payment_method_list(request):
    """Список способов оплаты"""
    methods = PaymentMethod.objects.all().order_by('id')
    context = {'methods': methods}
    return render(request, 'delservice_app/payment_method_list.html', context)


@login_required
def payment_method_create(request):
    """Создание способа оплаты"""
    if request.method == 'POST':
        form = PaymentMethodForm(request.POST)
        if form.is_valid():
            form.save()
            messages.success(request, 'Способ оплаты успешно создан')
            return redirect('delservice_app:payment_method_list')
    else:
        form = PaymentMethodForm()

    context = {'form': form, 'title': 'Создание способа оплаты'}
    return render(request, 'delservice_app/payment_method_form.html', context)


@login_required
def payment_method_update(request, method_id):
    """Редактирование способа оплаты"""
    method = get_object_or_404(PaymentMethod, id=method_id)

    if request.method == 'POST':
        form = PaymentMethodForm(request.POST, instance=method)
        if form.is_valid():
            form.save()
            messages.success(request, 'Способ оплаты успешно обновлён')
            return redirect('delservice_app:payment_method_list')
    else:
        form = PaymentMethodForm(instance=method)

    context = {'form': form, 'title': 'Редактирование способа оплаты', 'method': method}
    return render(request, 'delservice_app/payment_method_form.html', context)


@login_required
def payment_method_delete(request, method_id):
    """Удаление способа оплаты"""
    method = get_object_or_404(PaymentMethod, id=method_id)

    if request.method == 'POST':
        method.delete()
        messages.success(request, 'Способ оплаты успешно удалён')
        return redirect('delservice_app:payment_method_list')

    context = {'method': method}
    return render(request, 'delservice_app/payment_method_confirm_delete.html', context)


@login_required
def order_detail(request, order_id):
    """Детальная информация о заказе"""
    order = get_object_or_404(Order, id=order_id)
    items = order.items.select_related('product')

    # Вычисляем сумму для каждого товара
    for item in items:
        item.total_price = item.price_at_order * item.quantity

    # Проверка наличия оплаты и отзыва
    payment = getattr(order, 'payment', None)
    review = getattr(order, 'review', None)

    context = {
        'order': order,
        'items': items,
        'payment': payment,
        'review': review,
    }
    return render(request, 'delservice_app/order_detail.html', context)


@login_required
def order_item_create(request, order_id):
    """Добавление товара к заказу"""
    order = get_object_or_404(Order, id=order_id)

    if request.method == 'POST':
        product_id = request.POST.get('product')
        quantity = int(request.POST.get('quantity', 1))

        product = get_object_or_404(Product, id=product_id)

        # Создаем запись о товаре в заказе
        order_item = OrderItem.objects.create(
            order=order,
            product=product,
            quantity=quantity,
            price_at_order=product.price
        )

        # Пересчитываем общую стоимость заказа
        order.order_total += order_item.price_at_order * order_item.quantity
        order.save()

        messages.success(request, f'Товар "{product.name}" добавлен в заказ')
        return redirect('delservice_app:order_detail', order_id=order.id)

    products = Product.objects.all()
    context = {
        'order': order,
        'products': products,
    }
    return render(request, 'delservice_app/order_item_form.html', context)


@login_required
def order_item_delete(request, item_id):
    """Удаление товара из заказа"""
    item = get_object_or_404(OrderItem, id=item_id)
    order = item.order

    if request.method == 'POST':
        # Вычитаем стоимость товара из общей суммы
        order.order_total -= item.price_at_order * item.quantity
        order.save()

        item.delete()
        messages.success(request, 'Товар удалён из заказа')
        return redirect('delservice_app:order_detail', order_id=order.id)

    context = {'item': item}
    return render(request, 'delservice_app/order_item_confirm_delete.html', context)


from django.contrib.auth import logout as auth_logout

from django.contrib.auth import logout as auth_logout


@login_required
def logout_confirm(request):
    """Страница подтверждения выхода"""
    if request.method == 'POST':
        auth_logout(request)
        messages.success(request, 'Вы успешно вышли из системы')
        return redirect('login')

    return render(request, 'delservice_app/logout_confirm.html')