from django.db import models

class Role(models.Model):
    name = models.CharField(max_length=50, unique=True)
    description = models.TextField(blank=True, null=True)

    def __str__(self):
        return self.name

    class Meta:
        db_table = 'roles'

class User(models.Model):
    role = models.ForeignKey(Role, on_delete=models.CASCADE, related_name='users')
    login = models.CharField(max_length=50, unique=True)
    password_hash = models.CharField(max_length=255)
    full_name = models.CharField(max_length=255)
    phone = models.CharField(max_length=20)
    status = models.CharField(max_length=20, default='works')
    hire_date = models.DateField()

    def __str__(self):
        return self.full_name

    class Meta:
        db_table = 'users'

class Client(models.Model):
    email = models.EmailField(unique=True)
    phone = models.CharField(max_length=20)
    full_name = models.CharField(max_length=255)
    registration_date = models.DateTimeField(auto_now_add=True)
    status = models.CharField(max_length=20, default='active')

    def __str__(self):
        return self.full_name

    class Meta:
        db_table = 'clients'

class Address(models.Model):
    street = models.CharField(max_length=255)
    house_number = models.CharField(max_length=20)
    apartment_number = models.CharField(max_length=10, blank=True, null=True)
    entrance = models.CharField(max_length=10, blank=True, null=True)
    floor = models.IntegerField(blank=True, null=True)
    door_code = models.CharField(max_length=10, blank=True, null=True)
    latitude = models.DecimalField(max_digits=10, decimal_places=7, blank=True, null=True)  # Широта
    longitude = models.DecimalField(max_digits=10, decimal_places=7, blank=True, null=True)  # Долгота

    def __str__(self):
        return f"{self.street}, {self.house_number}"

    class Meta:
        db_table = 'addresses'

class OrderStatus(models.Model):
    code = models.CharField(max_length=20, unique=True)
    name = models.CharField(max_length=50)
    sort_order = models.SmallIntegerField()

    def __str__(self):
        return self.name

    class Meta:
        db_table = 'order_statuses'

class PaymentMethod(models.Model):
    code = models.CharField(max_length=20, unique=True)
    name = models.CharField(max_length=50)
    fee_percent = models.DecimalField(max_digits=5, decimal_places=2, default=0)

    def __str__(self):
        return self.name

    class Meta:
        db_table = 'payment_methods'

class Product(models.Model):
    name = models.CharField(max_length=255)
    description = models.TextField(blank=True, null=True)
    price = models.DecimalField(max_digits=10, decimal_places=2)
    weight_kg = models.DecimalField(max_digits=5, decimal_places=2)
    dimensions_cm = models.CharField(max_length=50, blank=True, null=True)

    def __str__(self):
        return self.name

    class Meta:
        db_table = 'products'

class Order(models.Model):
    client = models.ForeignKey(Client, on_delete=models.CASCADE, related_name='orders')
    delivery_address = models.ForeignKey(Address, on_delete=models.CASCADE, related_name='delivery_orders')
    pickup_address = models.ForeignKey(Address, on_delete=models.SET_NULL, null=True, blank=True, related_name='pickup_orders')
    courier = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True, related_name='delivered_orders')
    status = models.ForeignKey(OrderStatus, on_delete=models.CASCADE)
    delivery_cost = models.DecimalField(max_digits=10, decimal_places=2)
    order_total = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    payment_method = models.ForeignKey(PaymentMethod, on_delete=models.CASCADE)
    created_at = models.DateTimeField(auto_now_add=True)
    confirmed_at = models.DateTimeField(null=True, blank=True)
    courier_assigned_at = models.DateTimeField(null=True, blank=True)
    dispatched_at = models.DateTimeField(null=True, blank=True)
    delivered_at = models.DateTimeField(null=True, blank=True)
    comment = models.TextField(blank=True, null=True)

    def __str__(self):
        return f"Заказ #{self.id}"

    class Meta:
        db_table = 'orders'

class OrderItem(models.Model):
    order = models.ForeignKey(Order, on_delete=models.CASCADE, related_name='items')
    product = models.ForeignKey(Product, on_delete=models.CASCADE)
    quantity = models.SmallIntegerField(default=1)
    price_at_order = models.DecimalField(max_digits=10, decimal_places=2)

    def __str__(self):
        return f"{self.product.name} x {self.quantity}"

    class Meta:
        db_table = 'order_items'

class Review(models.Model):
    order = models.OneToOneField(Order, on_delete=models.CASCADE, related_name='review')
    rating = models.SmallIntegerField()
    text = models.TextField(blank=True, null=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Отзыв к заказу #{self.order.id}"

    class Meta:
        db_table = 'reviews'

class Payment(models.Model):
    order = models.OneToOneField(Order, on_delete=models.CASCADE, related_name='payment')
    payment_method = models.ForeignKey(PaymentMethod, on_delete=models.CASCADE)
    amount = models.DecimalField(max_digits=10, decimal_places=2)
    status = models.CharField(max_length=20)
    transaction_number = models.CharField(max_length=100, blank=True, null=True)
    paid_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Оплата заказа #{self.order.id}"

    class Meta:
        db_table = 'payments'